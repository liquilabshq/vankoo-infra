# Capa messaging: el broker de eventos de Vankoo en Azure. Es un namespace de
# Azure Event Hubs, que habla el protocolo de Kafka: los servicios usan los
# mismos clientes que con el Kafka del compose y solo cambian la dirección y la
# autenticación (SASL_SSL).
#
# Por qué es una capa aparte: el namespace cobra por hora aunque nadie lo use,
# y no se puede pausar. azure-stop.sh destruye esta capa entera y
# azure-deploy.sh la vuelve a crear; los eventos de una demo no hace falta
# conservarlos.

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

locals {
  suffix = data.terraform_remote_state.core.outputs.suffix

  # Un event hub por topic de Kafka, con el mismo nombre que en el compose.
  # Event Hubs no deja crear topics desde los clientes, así que tienen que
  # existir antes de que arranquen los servicios. El nivel Standard admite 10
  # y Vankoo los usa todos: un topic más obliga a subir de nivel o a juntar
  # topics.
  topics = toset([
    "vankoo.iam.events",
    "vankoo.profile.events",
    "vankoo.finance.events.v1",
    "invoicing.invoice-eligible-for-funding",
    "investment.auction-lifecycle.v1",
    "risk.company-verifications.v1",
    "risk.green-certifications.v1",
    # Colas de mensajes que un consumidor no pudo procesar (dead letter queues).
    "invoicing.auction-lifecycle.dlq",
    "investment.auction-lifecycle.v1.dlq",
    "notification.delivery.dlq",
  ])

  # Una regla de acceso por servicio: si una clave se filtra, se revoca solo esa.
  clients = toset(["iam", "invoicing", "profile", "finance", "investment", "notification"])
}

# Standard es el nivel más barato con endpoint de Kafka (el Basic no lo tiene).
# Una unidad de rendimiento (1 MB/s de entrada) sobra para Vankoo.
resource "azurerm_eventhub_namespace" "vankoo" {
  name                = "vankoo-events-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  sku                 = "Standard"
  capacity            = 1
  minimum_tls_version = "1.2"
}

# Una partición conserva el orden de todos los eventos de un topic, que es lo
# que esperan los consumidores. Un día de retención basta para una demo.
resource "azurerm_eventhub" "topics" {
  for_each = local.topics

  name              = each.value
  namespace_id      = azurerm_eventhub_namespace.vankoo.id
  partition_count   = 1
  message_retention = 1
}

# Envía y escucha, pero no administra: un servicio no puede crear ni borrar
# event hubs.
resource "azurerm_eventhub_namespace_authorization_rule" "clients" {
  for_each = local.clients

  name                = each.value
  namespace_name      = azurerm_eventhub_namespace.vankoo.name
  resource_group_name = data.azurerm_resource_group.vankoo.name
  listen              = true
  send                = true
  manage              = false
}
