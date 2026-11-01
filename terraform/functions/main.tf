# Capa functions: la función serverless de verificación de DNI del inversor
# (repo vankoo-dni-verification-function). Plan de consumo: no cuesta nada
# parada, solo la cuenta de almacenamiento (céntimos al mes).
#
# Por qué no se destruye con azure-destroy.sh (salvo --all): igual que core,
# no cuesta mientras no se usa, y conservarla mantiene la URL, la clave de la
# función y el código ya publicado. El código no lo despliega Terraform: lo
# publica el workflow deploy.yml del repo de la función.

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

# Azure Functions guarda aquí su estado interno (claves, coordinación del host).
# 24 caracteres como máximo, solo minúsculas y números.
resource "azurerm_storage_account" "functions" {
  name                            = "vankoofn${local.suffix}"
  resource_group_name             = data.azurerm_resource_group.vankoo.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

# Los logs de la función van al mismo workspace que las Container Apps.
resource "azurerm_application_insights" "functions" {
  name                = "vankoo-functions-insights"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  workspace_id        = data.terraform_remote_state.core.outputs.log_analytics_workspace_id
  application_type    = "web"
}

# Y1 = plan de consumo en Linux (pago por ejecución). Si la suscripción no
# tiene cuota para él en la región, ver la variable service_plan_sku.
resource "azurerm_service_plan" "functions" {
  name                = "vankoo-functions-plan"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.service_plan_sku
}

resource "azurerm_linux_function_app" "dni_verification" {
  name                = "vankoo-dni-verification-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.functions.id

  storage_account_name       = azurerm_storage_account.functions.name
  storage_account_access_key = azurerm_storage_account.functions.primary_access_key

  functions_extension_version = "~4"
  https_only                  = true

  site_config {
    application_insights_connection_string = azurerm_application_insights.functions.connection_string

    application_stack {
      python_version = "3.12"
    }
  }

  app_settings = {
    # La función lee estas variables en dni_verification/infrastructure/settings.py.
    DNI_PROVIDER          = var.dni_provider
    ELDNI_BASE_URL        = "https://eldni.com"
    ELDNI_TIMEOUT_SECONDS = "8"
    ELDNI_RETRIES         = "1"
    # El workflow publica con build remoto (Oryx): instala requirements.txt en Azure.
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
  }

  tags = {
    "vankoo-service" = "dni-verification-function"
  }
}
