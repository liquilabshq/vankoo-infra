# El estado vive en la cuenta de almacenamiento que crea scripts/azure/bootstrap-state.sh.
# Los scripts pasan el nombre de la cuenta y la clave (<capa>.tfstate) con -backend-config.
terraform {
  required_version = ">= 1.9"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# El equipo solo tiene acceso al grupo de recursos, no a la suscripción: el
# proveedor no debe intentar registrar resource providers (daría 403).
# La suscripción llega por ARM_SUBSCRIPTION_ID, que exportan los scripts.
provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}
