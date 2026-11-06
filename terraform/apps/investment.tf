# Investment y su base de datos Oracle. Terraform lee todos los .tf de la capa
# como uno solo: van aparte de main.tf solo para que cada servicio nuevo se lea
# entero en un archivo.

# --- Oracle de Investment -----------------------------------------------------
# Investment solo funciona con Oracle (ojdbc11 y Flyway para Oracle) y Azure no
# ofrece un Oracle administrado barato, así que corre la misma imagen del compose
# (Oracle Database Free) en una Container App, con ingress TCP interno en el 1521.
#
# Sus datos viven solo en el contenedor: Oracle no es fiable sobre un file share
# de red. Al reiniciarse, Flyway vuelve a crear el esquema vacío. La etiqueta
# vankoo-data = ephemeral hace que azure-stop.sh avise antes de detenerla.

resource "random_password" "investment_db_admin" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "investment_db" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "azurerm_container_app" "investment_db" {
  name                         = local.investment_db_app
  resource_group_name          = data.azurerm_resource_group.vankoo.name
  container_app_environment_id = local.core.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  tags = {
    "vankoo-data" = "ephemeral"
  }

  secret {
    name  = "oracle-admin-password"
    value = random_password.investment_db_admin.result
  }

  secret {
    name  = "oracle-app-password"
    value = random_password.investment_db.result
  }

  ingress {
    external_enabled = false
    transport        = "tcp"
    target_port      = 1521
    exposed_port     = 1521

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name  = "oracle"
      image = "docker.io/gvenzl/oracle-free:23-slim-faststart"
      # Oracle necesita al menos 2 GiB de memoria para arrancar.
      cpu    = 1
      memory = "2Gi"

      env {
        name        = "ORACLE_PASSWORD"
        secret_name = "oracle-admin-password"
      }
      # La imagen crea este usuario en FREEPDB1 al arrancar: es el de Investment.
      env {
        name  = "APP_USER"
        value = local.investment_db_user
      }
      env {
        name        = "APP_USER_PASSWORD"
        secret_name = "oracle-app-password"
      }

      startup_probe {
        transport               = "TCP"
        port                    = 1521
        initial_delay           = 10
        interval_seconds        = 10
        failure_count_threshold = 30
      }
      liveness_probe {
        transport = "TCP"
        port      = 1521
      }
    }
  }
}

# --- Investment Service -------------------------------------------------------
# Se despliega con azure-deploy.sh (build-push.sh), como el gateway.

resource "azurerm_container_app" "investment" {
  name                         = local.investment_app
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
    name  = "investment-db-password"
    value = random_password.investment_db.result
  }

  secret {
    name  = "jwt-secret"
    value = random_password.jwt_secret.result
  }

  secret {
    name  = "kafka-connection-string"
    value = lookup(local.msg.kafka_connection_strings, "investment", "")
  }

  ingress {
    external_enabled = false
    target_port      = 8082

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "investment-service"
      image  = var.images["investment-service"]
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = "azure"
      }
      env {
        name  = "INVESTMENT_DB_HOST"
        value = azurerm_container_app.investment_db.name
      }
      env {
        name  = "INVESTMENT_DB_USER"
        value = local.investment_db_user
      }
      env {
        name        = "INVESTMENT_DB_PASSWORD"
        secret_name = "investment-db-password"
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "JWT_EXPIRATION_DAYS"
        value = tostring(var.jwt_expiration_days)
      }
      # Kafka contra Azure Event Hubs (capa messaging).
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
      # URLs de la documentación (Scalar): la del servicio y la del gateway.
      env {
        name  = "INVESTMENT_PUBLIC_HOST"
        value = "${local.investment_app}.internal.${local.domain}"
      }
      env {
        name  = "INVESTMENT_GATEWAY_HOST"
        value = "${local.gateway_app}.${local.domain}"
      }

      # Espera a que Oracle termine de arrancar y a que Flyway cree el esquema.
      startup_probe {
        transport               = "HTTP"
        port                    = 8082
        path                    = "/actuator/health/liveness"
        initial_delay           = 10
        interval_seconds        = 10
        failure_count_threshold = 30
      }
      liveness_probe {
        transport = "HTTP"
        port      = 8082
        path      = "/actuator/health/liveness"
      }
      readiness_probe {
        transport = "HTTP"
        timeout   = 5
        port      = 8082
        path      = "/actuator/health/readiness"
      }
    }
  }
}
