# Capa data: una base de datos por servicio, como en el diagrama de
# contenedores. Fase 1: IAM (PostgreSQL) e Invoicing (MongoDB). Se destruye al
# apagar; los datos de demo se vuelven a sembrar al encender.

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
  suffix         = data.terraform_remote_state.core.outputs.suffix
  admin_username = "vankooadmin"
}

# --- IAM Database (PostgreSQL) ----------------------------------------------

# Sin caracteres especiales: la contraseña viaja en URLs de conexión y así no
# hay que escaparla.
resource "random_password" "iam_db" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "azurerm_postgresql_flexible_server" "iam" {
  name                          = "vankoo-iam-db-${local.suffix}"
  resource_group_name           = data.azurerm_resource_group.vankoo.name
  location                      = var.location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 7
  administrator_login           = local.admin_username
  administrator_password        = random_password.iam_db.result
  public_network_access_enabled = true

  # Azure elige la zona al crear el servidor; sin esto Terraform querría
  # cambiarla en cada plan.
  lifecycle {
    ignore_changes = [zone]
  }
}

# 0.0.0.0 es la regla especial de Azure para «permitir servicios de Azure»:
# deja entrar a las Container Apps sin abrir la base a internet.
resource "azurerm_postgresql_flexible_server_firewall_rule" "iam_allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.iam.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "iam" {
  name      = "vankoo_iam_db"
  server_id = azurerm_postgresql_flexible_server.iam.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# --- Invoicing Database (MongoDB) -------------------------------------------

resource "random_password" "invoicing_db" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

# Azure Cosmos DB for MongoDB (vCore) en nivel Free: uno por suscripción.
resource "azurerm_mongo_cluster" "invoicing" {
  name                   = "vankoo-invoicing-db-${local.suffix}"
  resource_group_name    = data.azurerm_resource_group.vankoo.name
  location               = var.location
  administrator_username = local.admin_username
  administrator_password = random_password.invoicing_db.result
  compute_tier           = "Free"
  high_availability_mode = "Disabled"
  shard_count            = 1
  storage_size_in_gb     = 32
  version                = "7.0"
  public_network_access  = "Enabled"
}

resource "azurerm_mongo_cluster_firewall_rule" "invoicing_allow_azure" {
  name             = "AllowAzureServices"
  mongo_cluster_id = azurerm_mongo_cluster.invoicing.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

locals {
  # Azure devuelve la cadena con marcadores <user> y <password>.
  invoicing_db_connection_string = replace(
    replace(
      azurerm_mongo_cluster.invoicing.connection_strings[0].value,
      "<user>", local.admin_username
    ),
    "<password>", random_password.invoicing_db.result
  )
}
