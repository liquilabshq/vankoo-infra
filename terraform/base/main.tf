# Capa base: el registro de imágenes. Se destruye al apagar (cobra por día).

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
}

# Usuario administrador habilitado: las Container Apps bajan las imágenes con
# ese usuario y contraseña. La alternativa (identidad administrada con rol
# AcrPull) necesita asignar roles, y el equipo solo tiene acceso de contribuidor
# al grupo.
resource "azurerm_container_registry" "acr" {
  name                = "vankooacr${local.suffix}"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = true
}
