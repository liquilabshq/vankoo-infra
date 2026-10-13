# Capa apps: una Container App por servicio. Solo el gateway acepta tráfico de
# internet; el resto tiene ingress interno y el gateway los alcanza por el DNS
# del environment (http://<nombre-de-la-app>). Fase 1: gateway, IAM e Invoicing.

data "azurerm_resource_group" "vankoo" {
  name = var.resource_group_name
}

data "terraform_remote_state" "core" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "core.tfstate"
  }
}

data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "base.tfstate"
  }
}

data "terraform_remote_state" "data" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "data.tfstate"
  }
}

locals {
  core = data.terraform_remote_state.core.outputs
  base = data.terraform_remote_state.base.outputs
  db   = data.terraform_remote_state.data.outputs

  domain = local.core.environment_default_domain

  gateway_app   = "vankoo-api-gateway"
  iam_app       = "vankoo-iam-service"
  invoicing_app = "vankoo-invoicing-service"
}

# Clave de firma de los JWT: la generan Terraform y la comparten IAM (firma) y
# el gateway (valida). Nadie tiene que conocerla.
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

# --- IAM Service --------------------------------------------------------------

resource "azurerm_container_app" "iam" {
  name                         = local.iam_app
  resource_group_name          = data.azurerm_resource_group.vankoo.name
  container_app_environment_id = local.core.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  registry {
    server               = local.base.acr_login_server
    username             = local.base.acr_admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = local.base.acr_admin_password
  }

  secret {
    name  = "jwt-secret"
    value = random_password.jwt_secret.result
  }

  secret {
    name  = "iam-db-password"
    value = local.db.iam_db_password
  }

  ingress {
    external_enabled = false
    target_port      = 8081

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "iam-service"
      image  = var.images["iam-service"]
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = "azure"
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "JWT_EXPIRATION_DAYS"
        value = tostring(var.jwt_expiration_days)
      }
      env {
        name  = "IAM_DB_HOST"
        value = local.db.iam_db_host
      }
      env {
        name  = "IAM_DB_NAME"
        value = local.db.iam_db_name
      }
      env {
        name  = "IAM_DB_USERNAME"
        value = local.db.iam_db_username
      }
      env {
        name        = "IAM_DB_PASSWORD"
        secret_name = "iam-db-password"
      }
      env {
        name  = "PASSWORD_RESET_WEB_URL"
        value = "${var.web_app_url}/iam/reset"
      }
      # Servidores que IAM anuncia en su documentación OpenAPI.
      env {
        name  = "IAM_PUBLIC_HOST"
        value = "${local.iam_app}.internal.${local.domain}"
      }
      env {
        name  = "IAM_GATEWAY_HOST"
        value = "${local.gateway_app}.${local.domain}"
      }

      # Spring Boot tarda en arrancar: la sonda de arranque le da hasta 5 min
      # antes de que empiecen a contar las otras dos.
      startup_probe {
        transport               = "HTTP"
        port                    = 8081
        path                    = "/actuator/health/liveness"
        interval_seconds        = 10
        failure_count_threshold = 30
      }
      liveness_probe {
        transport = "HTTP"
        port      = 8081
        path      = "/actuator/health/liveness"
      }
      readiness_probe {
        transport = "HTTP"
        # Por defecto Container Apps espera 1 s, y el chequeo de readiness
        # consulta dependencias externas: con 1 s caducaba y la app nunca
        # recibía tráfico.
        timeout = 5
        port    = 8081
        path    = "/actuator/health/readiness"
      }
    }
  }
}

# --- Invoicing Service --------------------------------------------------------

resource "azurerm_container_app" "invoicing" {
  name                         = local.invoicing_app
  resource_group_name          = data.azurerm_resource_group.vankoo.name
  container_app_environment_id = local.core.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  registry {
    server               = local.base.acr_login_server
    username             = local.base.acr_admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = local.base.acr_admin_password
  }

  secret {
    name  = "invoicing-db-connection-string"
    value = local.db.invoicing_db_connection_string
  }

  secret {
    name  = "ocr-api-key"
    value = local.core.ocr_key
  }

  secret {
    name  = "aws-access-key-id"
    value = var.aws_access_key_id
  }

  secret {
    name  = "aws-secret-access-key"
    value = var.aws_secret_access_key
  }

  ingress {
    external_enabled = false
    target_port      = 8080

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "invoicing-service"
      image  = var.images["invoicing-service"]
      cpu    = 0.5
      memory = "1Gi"

      # Cualquier nombre distinto de Production publica /openapi y /scalar,
      # que el gateway agrega en su propio Scalar.
      env {
        name  = "ASPNETCORE_ENVIRONMENT"
        value = "Azure"
      }
      env {
        name        = "DbSettings__ConnectionString"
        secret_name = "invoicing-db-connection-string"
      }
      env {
        name  = "DbSettings__DatabaseName"
        value = "vankoo_invoicing_db"
      }
      env {
        name  = "AzureOcrSettings__Endpoint"
        value = local.core.ocr_endpoint
      }
      env {
        name        = "AzureOcrSettings__ApiKey"
        secret_name = "ocr-api-key"
      }
      env {
        name  = "StorageProviderSettings__Provider"
        value = "AwsS3"
      }
      env {
        name  = "AwsS3Settings__Region"
        value = var.aws_region
      }
      env {
        name  = "AwsS3Settings__BucketName"
        value = var.aws_s3_bucket
      }
      env {
        name        = "AwsS3Settings__AccessKey"
        secret_name = "aws-access-key-id"
      }
      env {
        name        = "AwsS3Settings__SecretKey"
        secret_name = "aws-secret-access-key"
      }
      # Sin discovery server en Azure: el gateway llega por el DNS del environment.
      env {
        name  = "Eureka__Client__Enabled"
        value = "false"
      }
      env {
        name  = "Eureka__Client__ShouldRegisterWithEureka"
        value = "false"
      }
      env {
        name  = "Eureka__Client__ShouldFetchRegistry"
        value = "false"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/health/live"
      }
      readiness_probe {
        transport = "HTTP"
        # Por defecto Container Apps espera 1 s, y el chequeo de readiness
        # consulta dependencias externas: con 1 s caducaba y la app nunca
        # recibía tráfico.
        timeout = 5
        port    = 8080
        # PARCHE TEMPORAL (fase 1, sin Kafka en Azure): /health/ready incluye el
        # chequeo de Kafka, que sin broker no falla rápido sino que espera hasta
        # 60 s (MessageTimeout del productor). La sonda caduca siempre y la app
        # nunca recibe tráfico. Volver a "/health/ready" cuando Kafka esté
        # desplegado en el environment (fase 2).
        path = "/health/live"
      }
    }
  }
}

# --- API Gateway --------------------------------------------------------------

resource "azurerm_container_app" "gateway" {
  name                         = local.gateway_app
  resource_group_name          = data.azurerm_resource_group.vankoo.name
  container_app_environment_id = local.core.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  registry {
    server               = local.base.acr_login_server
    username             = local.base.acr_admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = local.base.acr_admin_password
  }

  secret {
    name  = "jwt-secret"
    value = random_password.jwt_secret.result
  }

  ingress {
    external_enabled = true
    target_port      = 8080

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "api-gateway"
      image  = var.images["api-gateway"]
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = "azure"
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "ALLOWED_ORIGINS"
        value = var.allowed_origins
      }
      # Destinos de las rutas (ver application-azure.yaml del gateway). Los
      # servicios que aún no están en Azure quedan sin variable y responden 503.
      env {
        name  = "IAM_SERVICE_URI"
        value = "http://${azurerm_container_app.iam.name}"
      }
      env {
        name  = "INVOICING_SERVICE_URI"
        value = "http://${azurerm_container_app.invoicing.name}"
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/actuator/health/liveness"
        interval_seconds        = 10
        failure_count_threshold = 30
      }
      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/actuator/health/liveness"
      }
      readiness_probe {
        transport = "HTTP"
        # Por defecto Container Apps espera 1 s, y el chequeo de readiness
        # consulta dependencias externas: con 1 s caducaba y la app nunca
        # recibía tráfico.
        timeout = 5
        port    = 8080
        path    = "/actuator/health/readiness"
      }
    }
  }
}
