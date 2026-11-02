# Capa functions: la función serverless de verificación de DNI del inversor
# (repo vankoo-dni-verification-function). Plan Flex Consumption: escala a cero
# y se paga por ejecución, así que parada no cuesta nada salvo la cuenta de
# almacenamiento (céntimos al mes).
#
# Por qué Flex Consumption y no el Consumption clásico (Y1): la suscripción no
# tiene cuota de «Y1 VMs» (límite 0), y Azure rechazaba el plan. Es el mismo
# Azure Functions, con el mismo código y los mismos disparadores; solo cambia
# el plan de hosting.
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

# Azure Functions guarda aquí su estado interno (claves, coordinación del host)
# y, en Flex, el paquete de código desplegado.
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

# Flex Consumption no usa el sistema de archivos de la app: el código se
# despliega como un paquete en este contenedor.
resource "azurerm_storage_container" "deployment" {
  name                  = "app-package-dni-verification"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

# Los logs de la función van al mismo workspace que las Container Apps.
resource "azurerm_application_insights" "functions" {
  name                = "vankoo-functions-insights"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  workspace_id        = data.terraform_remote_state.core.outputs.log_analytics_workspace_id
  application_type    = "web"
}

# FC1 = plan Flex Consumption (Linux).
resource "azurerm_service_plan" "functions" {
  name                = "vankoo-functions-plan"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "dni_verification" {
  name                = "vankoo-dni-verification-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.functions.id

  # Dónde se guarda el paquete de código que publica el workflow de despliegue.
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.functions.primary_access_key

  runtime_name    = "python"
  runtime_version = "3.12"

  # Tope de instancias (el mínimo que admite Flex): evita sorpresas de coste.
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  https_only = true

  site_config {
    application_insights_connection_string = azurerm_application_insights.functions.connection_string
  }

  app_settings = {
    # El host guarda aquí las claves de la función (x-functions-key).
    AzureWebJobsStorage = azurerm_storage_account.functions.primary_connection_string
    # La función lee estas variables en dni_verification/infrastructure/settings.py.
    DNI_PROVIDER          = var.dni_provider
    ELDNI_BASE_URL        = "https://eldni.com"
    ELDNI_TIMEOUT_SECONDS = "8"
    ELDNI_RETRIES         = "1"
  }

  tags = {
    "vankoo-service" = "dni-verification-function"
  }
}
