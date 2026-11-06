# Capa data: una base de datos por servicio, como en el diagrama de
# contenedores: PostgreSQL de IAM, Profile y Finance, MongoDB de Invoicing y el
# disco de Axon Server (event store de Finance). El Oracle de Investment vive en
# su Container App (capa apps). Se destruye al apagar; los datos de demo se
# vuelven a sembrar al encender.

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

# --- Profile Database (PostgreSQL) ------------------------------------------
# Igual que la de IAM. Profile crea sus tablas al arrancar (TypeORM synchronize)
# y se conecta por TLS (PROFILE_DB_SSL=true en su Container App).

resource "random_password" "profile_db" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "azurerm_postgresql_flexible_server" "profile" {
  name                          = "vankoo-profile-db-${local.suffix}"
  resource_group_name           = data.azurerm_resource_group.vankoo.name
  location                      = var.location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 7
  administrator_login           = local.admin_username
  administrator_password        = random_password.profile_db.result
  public_network_access_enabled = true

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "profile_allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.profile.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "profile" {
  name      = "vankoo_profile_db"
  server_id = azurerm_postgresql_flexible_server.profile.id
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

# --- Finance Database (PostgreSQL) -------------------------------------------
# Las proyecciones de Finance (depósitos, inbox de webhooks) y las tablas de
# infraestructura de Axon que crea Flyway. Mismo tamaño y reglas que IAM y Profile;
# Finance se conecta por TLS (sslmode=require en su perfil azure).

resource "random_password" "finance_db" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "azurerm_postgresql_flexible_server" "finance" {
  name                          = "vankoo-finance-db-${local.suffix}"
  resource_group_name           = data.azurerm_resource_group.vankoo.name
  location                      = var.location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 7
  administrator_login           = local.admin_username
  administrator_password        = random_password.finance_db.result
  public_network_access_enabled = true

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "finance_allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.finance.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "finance" {
  name      = "vankoo_finance_db"
  server_id = azurerm_postgresql_flexible_server.finance.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# --- Axon Server (event store de Finance) -----------------------------------
# Finance guarda sus eventos de dominio en Axon Server, no en PostgreSQL: si se
# pierden, las proyecciones quedan huérfanas. Por eso Axon guarda sus datos en un
# file share de Azure Files, que sobrevive a los reinicios y a azure-stop.sh, y que
# el environment monta en su Container App (capa apps).
#
# Por comprobar al desplegar: Axon Server usa archivos mapeados en memoria y una
# base H2 para su control, y no está documentado si funcionan sobre SMB. Si fallan,
# las alternativas son una VM con disco propio o el event store JPA de Axon en el
# PostgreSQL de Finance.

resource "azurerm_storage_account" "axon" {
  name                            = "vankooaxon${local.suffix}"
  resource_group_name             = data.azurerm_resource_group.vankoo.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_share" "axon" {
  name               = "axonserver"
  storage_account_id = azurerm_storage_account.axon.id
  quota              = 5
}

# El environment monta el share con este nombre; la Container App lo referencia.
resource "azurerm_container_app_environment_storage" "axon" {
  name                         = "axonserver"
  container_app_environment_id = data.terraform_remote_state.core.outputs.environment_id
  account_name                 = azurerm_storage_account.axon.name
  share_name                   = azurerm_storage_share.axon.name
  access_key                   = azurerm_storage_account.axon.primary_access_key
  access_mode                  = "ReadWrite"
}
