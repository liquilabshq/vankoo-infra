# Capa core: lo que no se destruye al apagar porque no cuesta nada parado: el
# sufijo que hace únicos los nombres globales, el OCR (Document Intelligence
# F0), el workspace de logs y el Container Apps Environment.
#
# Por qué el environment va aquí: su dominio (y con él la URL del gateway) es
# aleatorio y cambia si se recrea. Conservándolo, la URL es siempre la misma y
# la web y la app no hay que reconfigurarlas tras cada apagado. Sin apps dentro
# no cobra; el workspace solo cobra por los logs que recibe.
#
# Por qué el OCR va aquí y no en data: al borrar una cuenta de Cognitive
# Services, Azure la deja 48 h en papelera; vaciarla exige permisos de
# suscripción, y el nivel F0 admite una sola cuenta por suscripción. Recrearlo
# en cada encendido podría fallar. Como no cuesta nada, se queda.

data "azurerm_resource_group" "vankoo" {
  name = var.resource_group_name
}

# Sufijo para los nombres que Azure exige únicos en todo el mundo (registro,
# servidores de base de datos, subdominio del OCR). Vive en esta capa para que
# no cambie entre encendidos.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_cognitive_account" "ocr" {
  name                  = "vankoo-ocr-${random_string.suffix.result}"
  resource_group_name   = data.azurerm_resource_group.vankoo.name
  location              = var.location
  kind                  = "FormRecognizer"
  sku_name              = "F0"
  custom_subdomain_name = "vankoo-ocr-${random_string.suffix.result}"
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "vankoo-logs"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# Environment con perfiles de carga (el «normal», no Express): es el que da DNS
# interno entre apps e ingress interno, y TCP interno para Kafka, Axon y Oracle.
# Con solo el perfil Consumption no hay coste fijo.
#
# Va con azapi y no con azurerm_container_app_environment porque, si no se pide
# el modo explícitamente, Azure crea un environment Express. azurerm 4.x no
# tiene ese campo (hashicorp/terraform-provider-azurerm#33564); la API lo
# acepta desde la versión 2026-07-01.
resource "azapi_resource" "environment" {
  type      = "Microsoft.App/managedEnvironments@2026-07-01"
  name      = "vankoo-env"
  parent_id = data.azurerm_resource_group.vankoo.id
  location  = var.location

  # azapi 2.13 trae el esquema solo hasta 2026-01-01 y rechazaría la versión.
  # Azure sí la acepta; quitar esta línea cuando azapi la incluya.
  schema_validation_enabled = false

  body = {
    properties = {
      environmentMode = "WorkloadProfiles"
      workloadProfiles = [
        {
          name                = "Consumption"
          workloadProfileType = "Consumption"
        }
      ]
      appLogsConfiguration = {
        destination = "log-analytics"
        logAnalyticsConfiguration = {
          customerId = azurerm_log_analytics_workspace.logs.workspace_id
        }
      }
    }
  }

  # La clave del workspace va aparte para que no salga en los planes.
  sensitive_body = {
    properties = {
      appLogsConfiguration = {
        logAnalyticsConfiguration = {
          sharedKey = azurerm_log_analytics_workspace.logs.primary_shared_key
        }
      }
    }
  }

  response_export_values = ["properties.defaultDomain", "properties.environmentMode"]
}
