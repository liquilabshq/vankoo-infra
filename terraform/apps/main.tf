# Capa apps: una Container App por servicio. Solo el gateway acepta tráfico de
# internet; el resto tiene ingress interno y el gateway los alcanza por el DNS
# del environment (http://<nombre-de-la-app>). Fase 1: gateway, IAM, Invoicing y
# Profile.

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

# azure-stop.sh destruye la capa messaging, y su estado queda sin salidas. Los
# valores por defecto dejan que azure-destroy.sh destruya esta capa igualmente;
# azure-deploy.sh siempre vuelve a crear messaging antes de aplicar apps.
data "terraform_remote_state" "messaging" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "messaging.tfstate"
  }
  defaults = {
    kafka_bootstrap_server   = ""
    kafka_connection_strings = {}
  }
}

locals {
  core = data.terraform_remote_state.core.outputs
  base = data.terraform_remote_state.base.outputs
  db   = data.terraform_remote_state.data.outputs
  msg  = data.terraform_remote_state.messaging.outputs

  # Event Hubs se usa con el cliente de Kafka de siempre: TLS, mecanismo PLAIN,
  # el usuario literal $ConnectionString y, como contraseña, la cadena de
  # conexión de la regla del servicio (un secreto de cada Container App).
  kafka_bootstrap_server = local.msg.kafka_bootstrap_server
  kafka_sasl_username    = "$ConnectionString"

  domain = local.core.environment_default_domain

  gateway_app   = "vankoo-api-gateway"
  iam_app       = "vankoo-iam-service"
  invoicing_app = "vankoo-invoicing-service"
  profile_app   = "vankoo-profile-service"

  # La verificación automática del DNI se enciende al pasar la URL de la función.
  dni_verification_enabled = var.dni_verification_url != ""
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

  secret {
    name  = "kafka-connection-string"
    value = lookup(local.msg.kafka_connection_strings, "iam", "")
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
      # Kafka contra Azure Event Hubs (capa messaging). KAFKA_ENABLED activa el
      # publicador de eventos del perfil azure (vankoo.events.enabled).
      env {
        name  = "KAFKA_ENABLED"
        value = "true"
      }
      env {
        name  = "KAFKA_BROKERS"
        value = local.kafka_bootstrap_server
      }
      env {
        name  = "KAFKA_SASL_USERNAME"
        value = local.kafka_sasl_username
      }
      env {
        name        = "KAFKA_SASL_PASSWORD"
        secret_name = "kafka-connection-string"
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

  # Después de crearla, la imagen la cambia el pipeline del repo
  # (.github/workflows/deliver-container-app.yml); si Terraform la vigilara,
  # cada apply volvería a la de images.auto.tfvars.
  lifecycle {
    ignore_changes = [template[0].container[0].image]
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

  secret {
    name  = "kafka-connection-string"
    value = lookup(local.msg.kafka_connection_strings, "invoicing", "")
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
      # Kafka contra Azure Event Hubs (capa messaging). Ver docs/ARCHITECTURE.md de
      # vankoo-invoicing-service, «Conexión con Kafka».
      env {
        name  = "KafkaSettings__BootstrapServers"
        value = local.kafka_bootstrap_server
      }
      env {
        name  = "KafkaSettings__SecurityProtocol"
        value = "SaslSsl"
      }
      env {
        name  = "KafkaSettings__SaslMechanism"
        value = "Plain"
      }
      env {
        name  = "KafkaSettings__SaslUsername"
        value = local.kafka_sasl_username
      }
      env {
        name        = "KafkaSettings__SaslPassword"
        secret_name = "kafka-connection-string"
      }
      # Event Hubs exige más de 20 s por petición; el mensaje debe poder esperar más que eso.
      env {
        name  = "KafkaSettings__RequestTimeoutMs"
        value = "60000"
      }
      env {
        name  = "KafkaSettings__MessageTimeoutMs"
        value = "120000"
      }
      # Azure corta las conexiones inactivas a los 240 s.
      env {
        name  = "KafkaSettings__MetadataMaxAgeMs"
        value = "180000"
      }
      env {
        name  = "KafkaSettings__SocketKeepaliveEnable"
        value = "true"
      }
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
        # consulta dependencias externas (MongoDB, S3 y Kafka, este con hasta
        # 5 s de espera): con 1 s caducaba y la app nunca recibía tráfico.
        timeout = 10
        port    = 8080
        path    = "/health/ready"
      }
    }
  }

  # Igual que en IAM: la imagen la gestiona el pipeline del repo.
  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

# --- Profile Service ----------------------------------------------------------

resource "azurerm_container_app" "profile" {
  name                         = local.profile_app
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
    name  = "profile-db-password"
    value = local.db.profile_db_password
  }

  # Bucket y credenciales de S3 propios de Profile (no los de Invoicing).
  secret {
    name  = "aws-access-key-id"
    value = var.profile_aws_access_key_id
  }

  secret {
    name  = "aws-secret-access-key"
    value = var.profile_aws_secret_access_key
  }

  secret {
    name  = "kafka-connection-string"
    value = lookup(local.msg.kafka_connection_strings, "profile", "")
  }

  # Container Apps no admite secretos vacíos: solo se crea si hay clave.
  dynamic "secret" {
    for_each = var.dni_verification_key != "" ? [1] : []
    content {
      name  = "dni-verification-key"
      value = var.dni_verification_key
    }
  }

  ingress {
    external_enabled = false
    target_port      = 3000

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "profile-service"
      image  = var.images["profile-service"]
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "PORT"
        value = "3000"
      }
      env {
        name  = "PROFILE_DB_HOST"
        value = local.db.profile_db_host
      }
      env {
        name  = "PROFILE_DB_PORT"
        value = "5432"
      }
      env {
        name  = "PROFILE_DB_USER"
        value = local.db.profile_db_username
      }
      env {
        name        = "PROFILE_DB_PASS"
        secret_name = "profile-db-password"
      }
      env {
        name  = "PROFILE_DB_NAME"
        value = local.db.profile_db_name
      }
      # Azure Database for PostgreSQL exige TLS.
      env {
        name  = "PROFILE_DB_SSL"
        value = "true"
      }
      # Kafka contra Azure Event Hubs (capa messaging).
      env {
        name  = "KAFKA_ENABLED"
        value = "true"
      }
      env {
        name  = "KAFKA_BROKERS"
        value = local.kafka_bootstrap_server
      }
      env {
        name  = "KAFKA_SSL"
        value = "true"
      }
      env {
        name  = "KAFKA_SASL_MECHANISM"
        value = "plain"
      }
      env {
        name  = "KAFKA_SASL_USERNAME"
        value = local.kafka_sasl_username
      }
      env {
        name        = "KAFKA_SASL_PASSWORD"
        secret_name = "kafka-connection-string"
      }
      # Sin discovery server en Azure: el gateway llega por el DNS del environment.
      env {
        name  = "EUREKA_ENABLED"
        value = "false"
      }
      env {
        name  = "STORAGE_PROVIDER"
        value = "s3"
      }
      env {
        name  = "AWS_REGION"
        value = var.profile_aws_region
      }
      env {
        name  = "AWS_S3_BUCKET"
        value = var.profile_aws_s3_bucket
      }
      env {
        name        = "AWS_ACCESS_KEY_ID"
        secret_name = "aws-access-key-id"
      }
      env {
        name        = "AWS_SECRET_ACCESS_KEY"
        secret_name = "aws-secret-access-key"
      }
      env {
        name  = "DNI_VERIFICATION_ENABLED"
        value = tostring(local.dni_verification_enabled)
      }
      dynamic "env" {
        for_each = local.dni_verification_enabled ? [1] : []
        content {
          name  = "DNI_VERIFICATION_URL"
          value = var.dni_verification_url
        }
      }
      dynamic "env" {
        for_each = var.dni_verification_key != "" ? [1] : []
        content {
          name        = "DNI_VERIFICATION_KEY"
          secret_name = "dni-verification-key"
        }
      }

      # Profile no tiene endpoint de salud: GET /api/v1 (el «Hello» de
      # AppController) responde en cuanto Nest escucha. Las rutas son /api/v1/...
      startup_probe {
        transport               = "HTTP"
        port                    = 3000
        path                    = "/api/v1"
        interval_seconds        = 10
        failure_count_threshold = 30
      }
      liveness_probe {
        transport = "HTTP"
        port      = 3000
        path      = "/api/v1"
      }
      readiness_probe {
        transport = "HTTP"
        timeout   = 5
        port      = 3000
        path      = "/api/v1"
      }
    }
  }

  # Igual que en IAM: la imagen la gestiona el pipeline del repo.
  lifecycle {
    ignore_changes = [template[0].container[0].image]
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
      env {
        name  = "PROFILE_SERVICE_URI"
        value = "http://${azurerm_container_app.profile.name}"
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
