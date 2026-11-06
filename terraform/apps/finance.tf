# Finance y su event store, Axon Server. Terraform lee todos los .tf de la capa
# como uno solo: van aparte de main.tf solo para que cada servicio nuevo se lea
# entero en un archivo.

# --- Axon Server --------------------------------------------------------------
# Imagen pública de Docker Hub, la misma que el compose pero con versión fija.
# Ingress TCP interno: Finance llega por gRPC a vankoo-axon-server:8124. Sus datos
# (eventos, snapshots y la base de control) van al file share de la capa data,
# montado en /axonserver/data, para que sobrevivan a reinicios y a azure-stop.sh.

resource "azurerm_container_app" "axon" {
  name                         = local.axon_app
  resource_group_name          = data.azurerm_resource_group.vankoo.name
  container_app_environment_id = local.core.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  ingress {
    external_enabled = false
    transport        = "tcp"
    target_port      = 8124
    exposed_port     = 8124

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Un único servidor con estado: siempre encendido mientras Vankoo lo esté, y
    # nunca dos a la vez sobre los mismos archivos.
    min_replicas = 1
    max_replicas = 1

    volume {
      name         = "axonserver-data"
      storage_type = "AzureFile"
      storage_name = local.db.axon_storage_name
    }

    container {
      name   = "axon-server"
      image  = "docker.io/axoniq/axonserver:2026.1.7"
      cpu    = 0.5
      memory = "1Gi"

      volume_mounts {
        name = "axonserver-data"
        path = "/axonserver/data"
      }

      env {
        name  = "AXONIQ_AXONSERVER_STANDALONE"
        value = "true"
      }
      # Todo dentro del share: por defecto los eventos irían a /axonserver/events,
      # que es disco del contenedor y se pierde al reiniciar.
      env {
        name  = "AXONIQ_AXONSERVER_EVENT_STORAGE"
        value = "/axonserver/data/events"
      }
      env {
        name  = "AXONIQ_AXONSERVER_SNAPSHOT_STORAGE"
        value = "/axonserver/data/events"
      }

      startup_probe {
        transport               = "TCP"
        port                    = 8124
        initial_delay           = 10
        interval_seconds        = 5
        failure_count_threshold = 30
      }
      liveness_probe {
        transport = "TCP"
        port      = 8124
      }
    }
  }
}

# --- Finance Service ----------------------------------------------------------
# Se despliega con azure-deploy.sh (build-push.sh), como el gateway.

resource "azurerm_container_app" "finance" {
  name                         = local.finance_app
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
    name  = "finance-db-password"
    value = local.db.finance_db_password
  }

  secret {
    name  = "kafka-connection-string"
    value = lookup(local.msg.kafka_connection_strings, "finance", "")
  }

  # Container Apps no admite secretos vacíos: las claves de Stripe solo se crean
  # si llegan (TF_VAR_stripe_secret_key y TF_VAR_stripe_webhook_secret).
  dynamic "secret" {
    for_each = local.stripe_enabled ? [1] : []
    content {
      name  = "stripe-secret-key"
      value = var.stripe_secret_key
    }
  }

  dynamic "secret" {
    for_each = local.stripe_enabled ? [1] : []
    content {
      name  = "stripe-webhook-secret"
      value = var.stripe_webhook_secret
    }
  }

  ingress {
    external_enabled = false
    target_port      = 8083

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "finance-service"
      image  = var.images["finance-service"]
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = "azure"
      }
      env {
        name  = "FINANCE_DB_HOST"
        value = local.db.finance_db_host
      }
      env {
        name  = "FINANCE_DB_NAME"
        value = local.db.finance_db_name
      }
      env {
        name  = "FINANCE_DB_USERNAME"
        value = local.db.finance_db_username
      }
      env {
        name        = "FINANCE_DB_PASSWORD"
        secret_name = "finance-db-password"
      }
      env {
        name  = "AXON_SERVER_HOST"
        value = azurerm_container_app.axon.name
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
      # Sin claves de Stripe, Finance arranca pero rechaza crear depósitos
      # (stripe.enabled=false en StripePaymentProvider).
      env {
        name  = "STRIPE_ENABLED"
        value = tostring(local.stripe_enabled)
      }
      dynamic "env" {
        for_each = local.stripe_enabled ? [1] : []
        content {
          name        = "STRIPE_SECRET_KEY"
          secret_name = "stripe-secret-key"
        }
      }
      dynamic "env" {
        for_each = local.stripe_enabled ? [1] : []
        content {
          name        = "STRIPE_WEBHOOK_SECRET"
          secret_name = "stripe-webhook-secret"
        }
      }
      env {
        name  = "STRIPE_SUCCESS_URL"
        value = "vankoo://deposits/success"
      }
      env {
        name  = "STRIPE_CANCEL_URL"
        value = "vankoo://deposits/cancel"
      }
      # URLs de la documentación (Scalar): la del servicio y la del gateway.
      env {
        name  = "FINANCE_PUBLIC_HOST"
        value = "${local.finance_app}.internal.${local.domain}"
      }
      env {
        name  = "FINANCE_GATEWAY_HOST"
        value = "${local.gateway_app}.${local.domain}"
      }

      # Flyway, la conexión con Axon Server y la de Kafka: arranca más despacio que IAM.
      startup_probe {
        transport               = "HTTP"
        port                    = 8083
        path                    = "/actuator/health/liveness"
        initial_delay           = 10
        interval_seconds        = 5
        failure_count_threshold = 36
      }
      liveness_probe {
        transport = "HTTP"
        port      = 8083
        path      = "/actuator/health/liveness"
      }
      readiness_probe {
        transport = "HTTP"
        timeout   = 5
        port      = 8083
        path      = "/actuator/health/readiness"
      }
    }
  }
}
