# Notification: escucha los eventos de los demás servicios en Event Hubs y avisa a
# los usuarios. No tiene base de datos. Terraform lee todos los .tf de la capa
# como uno solo: va aparte de main.tf solo para que se lea entero en un archivo.
#
# Push y email van al log (proveedores "logging") hasta que se configuren Firebase
# y un SMTP real: el flujo de eventos se ve igual en los logs de la Container App.

# Con NODE_ENV=production el servicio exige un secreto propio para derivar el
# topic de push de cada usuario.
resource "random_password" "push_topic_secret" {
  length  = 32
  special = false
}

resource "azurerm_container_app" "notification" {
  name                         = local.notification_app
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
    name  = "push-topic-secret"
    value = random_password.push_topic_secret.result
  }

  secret {
    name  = "kafka-connection-string"
    value = lookup(local.msg.kafka_connection_strings, "notification", "")
  }

  ingress {
    external_enabled = false
    target_port      = 3001

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Siempre una réplica: es un consumidor de eventos, no recibe tráfico HTTP que
    # lo despierte si escala a cero.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "notification-service"
      image  = var.images["notification-service"]
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "PORT"
        value = "3001"
      }
      env {
        name  = "INSTANCE_HOSTNAME"
        value = local.notification_app
      }
      env {
        name  = "WEB_APP_URL"
        value = var.web_app_url
      }
      # Sin discovery server en Azure: llega a Profile por el DNS del environment.
      env {
        name  = "EUREKA_ENABLED"
        value = "false"
      }
      env {
        name  = "PROFILE_SERVICE_URL"
        value = "http://${azurerm_container_app.profile.name}"
      }
      # Kafka contra Azure Event Hubs (capa messaging).
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
      env {
        name  = "PUSH_PROVIDER"
        value = "logging"
      }
      env {
        name        = "PUSH_TOPIC_SECRET"
        secret_name = "push-topic-secret"
      }
      env {
        name  = "EMAIL_PROVIDER"
        value = "logging"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 3001
        path      = "/health/live"
      }
      # Listo cuando el consumidor de Kafka entra en su grupo.
      readiness_probe {
        transport = "HTTP"
        timeout   = 5
        port      = 3001
        path      = "/health/ready"
      }
    }
  }
}
