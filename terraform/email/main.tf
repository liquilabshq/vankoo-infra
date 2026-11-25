# Capa email: Azure Communication Services para los correos reales de Vankoo
# (bienvenida y avisos de Notification, recuperación de contraseña de IAM).
#
# - Email Communication Services con un dominio administrado por Azure
#   (*.azurecomm.net): no necesita DNS propio y queda verificado al crearse.
# - Communication Services, conectado a ese dominio. Los servicios envían por su
#   API REST con la cadena de conexión (clave de acceso), sin app de Entra: el
#   tenant de la UPC no deja registrar aplicaciones, que es lo que pide el SMTP.
#
# Coste: los recursos no cobran; cada correo cuesta una fracción de centavo. El
# dominio administrado tiene límites de envío bajos, suficientes para la demo.
# Es independiente de las demás capas: solo lee el sufijo de core.

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
  tags = {
    "vankoo-managed-by" = "terraform"
    "vankoo-layer"      = "email"
  }
}

resource "azurerm_email_communication_service" "vankoo" {
  name                = "vankoo-email-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  data_location       = var.data_location
  tags                = local.tags
}

resource "azurerm_email_communication_service_domain" "azure_managed" {
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.vankoo.id
  domain_management = "AzureManaged"
  tags              = local.tags
}

resource "azurerm_communication_service" "vankoo" {
  name                = "vankoo-acs-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  data_location       = var.data_location
  tags                = local.tags
}

resource "azurerm_communication_service_email_domain_association" "vankoo" {
  communication_service_id = azurerm_communication_service.vankoo.id
  email_service_domain_id  = azurerm_email_communication_service_domain.azure_managed.id
}
