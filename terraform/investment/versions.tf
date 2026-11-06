terraform {
  required_version = ">= 1.9"
  backend "azurerm" {}
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.81" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}
