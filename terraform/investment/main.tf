# Separate state: applying this layer cannot delete IAM, Invoicing or Profile.
data "azurerm_resource_group" "vankoo" { name = var.resource_group_name }
data "terraform_remote_state" "core" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "core.tfstate"
  }
}
data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "base.tfstate"
  }
}
locals {
  suffix = data.terraform_remote_state.core.outputs.suffix
  core   = data.terraform_remote_state.core.outputs
  base   = data.terraform_remote_state.base.outputs
  app    = "vankoo-investment-service"
  vm     = "vankoo-investment-db-vm"
}
resource "azurerm_virtual_network" "investment" {
  name                = "vankoo-investment-vnet"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.vankoo.name
  address_space       = [var.vnet_cidr]
}
resource "azurerm_subnet" "database" {
  name                 = "investment-db-subnet"
  resource_group_name  = data.azurerm_resource_group.vankoo.name
  virtual_network_name = azurerm_virtual_network.investment.name
  address_prefixes     = [var.subnet_cidr]
}
resource "azurerm_public_ip" "database" {
  name                = "vankoo-investment-db-ip"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.vankoo.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "vankoo-investment-db-${local.suffix}"
}
resource "azurerm_network_security_group" "database" {
  name                = "vankoo-investment-db-nsg"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.vankoo.name
}
resource "azurerm_network_security_rule" "oracle_tls" {
  count                       = length(var.database_client_cidrs) > 0 ? 1 : 0
  name                        = "AllowInvestmentOracleTLS"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "2484"
  source_address_prefixes     = var.database_client_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.vankoo.name
  network_security_group_name = azurerm_network_security_group.database.name
}
resource "azurerm_network_security_rule" "deny_database" {
  name                        = "DenyOtherDatabaseConnections"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["1521", "2484", "22"]
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.vankoo.name
  network_security_group_name = azurerm_network_security_group.database.name
}
resource "azurerm_network_interface" "database" {
  name                = "vankoo-investment-db-nic"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.vankoo.name
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.database.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.database.id
  }
}
resource "azurerm_network_interface_security_group_association" "database" {
  network_interface_id      = azurerm_network_interface.database.id
  network_security_group_id = azurerm_network_security_group.database.id
}
resource "azurerm_linux_virtual_machine" "database" {
  name                            = local.vm
  location                        = var.location
  resource_group_name             = data.azurerm_resource_group.vankoo.name
  size                            = var.vm_size
  admin_username                  = "vankooadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.database.id]
  admin_ssh_key {
    username   = "vankooadmin"
    public_key = var.investment_ssh_public_key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  tags       = { "vankoo-service" = "investment", "vankoo-data" = "persistent" }
  depends_on = [azurerm_network_interface_security_group_association.database, azurerm_network_security_rule.deny_database]
  lifecycle {
    prevent_destroy = true
  }
}
resource "azurerm_dev_test_global_vm_shutdown_schedule" "database" {
  virtual_machine_id    = azurerm_linux_virtual_machine.database.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = "2300"
  timezone              = "SA Pacific Standard Time"
  notification_settings { enabled = false }
}
resource "random_password" "oracle_admin" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}
resource "random_password" "oracle_app" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}
resource "random_password" "jwt" {
  length  = 64
  special = false
}
resource "tls_private_key" "database" {
  algorithm = "RSA"
  rsa_bits  = 3072
}
resource "tls_self_signed_cert" "database" {
  private_key_pem       = tls_private_key.database.private_key_pem
  validity_period_hours = 8760
  early_renewal_hours   = 168
  dns_names             = [azurerm_public_ip.database.fqdn]
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
  subject { common_name = azurerm_public_ip.database.fqdn }
}
resource "azurerm_virtual_machine_extension" "oracle" {
  name                       = "prepare-oracle"
  virtual_machine_id         = azurerm_linux_virtual_machine.database.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true
  # Never put credentials in custom_data, public settings, outputs or logs.
  protected_settings = jsonencode({
    script = base64encode(templatefile("${path.module}/oracle-install.sh.tftpl", {
      admin_password_b64 = base64encode(random_password.oracle_admin.result)
      app_password_b64   = base64encode(random_password.oracle_app.result)
      certificate_b64    = base64encode(tls_self_signed_cert.database.cert_pem)
      private_key_b64    = base64encode(tls_private_key.database.private_key_pem)
    }))
  })
}
resource "azurerm_container_app" "investment" {
  name                         = local.app
  resource_group_name          = data.azurerm_resource_group.vankoo.name
  container_app_environment_id = local.core.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  registry {
    server               = local.base.acr_login_server
    username             = local.base.acr_admin_username
    password_secret_name = "acr-password"
  }
  secret {
    name  = "acr-password"
    value = local.base.acr_admin_password
  }
  secret {
    name  = "oracle-password"
    value = random_password.oracle_app.result
  }
  secret {
    name  = "jwt-secret"
    value = random_password.jwt.result
  }
  ingress {
    external_enabled           = var.bootstrap ? false : var.external_ingress
    target_port                = var.bootstrap ? 80 : 8082
    allow_insecure_connections = false
    dynamic "ip_security_restriction" {
      for_each = var.external_ingress && !var.bootstrap ? toset(var.api_client_cidrs) : toset([])
      content {
        name             = "demo-${replace(ip_security_restriction.value, "/", "-")}"
        action           = "Allow"
        ip_address_range = ip_security_restriction.value
      }
    }
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
  template {
    min_replicas = var.bootstrap ? 0 : 1
    max_replicas = 1
    container {
      name   = "investment-service"
      image  = var.bootstrap ? "mcr.microsoft.com/k8se/quickstart:latest" : var.image
      cpu    = var.bootstrap ? 0.25 : 1
      memory = var.bootstrap ? "0.5Gi" : "2Gi"
      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = "azure"
      }
      env {
        name  = "INVESTMENT_DB_URL"
        value = "jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=${azurerm_public_ip.database.fqdn})(PORT=2484))(CONNECT_DATA=(SERVICE_NAME=FREEPDB1))(SECURITY=(SSL_SERVER_DN_MATCH=YES)))"
      }
      env {
        name  = "INVESTMENT_DB_USER"
        value = "VANKOO_INVESTMENT"
      }
      env {
        name        = "INVESTMENT_DB_PASSWORD"
        secret_name = "oracle-password"
      }
      env {
        name  = "INVESTMENT_DB_TLS_CERT_BASE64"
        value = base64encode(tls_self_signed_cert.database.cert_pem)
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name  = "INVESTMENT_MESSAGING_ENABLED"
        value = "false"
      }
      env {
        name  = "INVESTMENT_PUBLIC_URL"
        value = "https://${local.app}.${var.external_ingress ? "" : "internal."}${local.core.environment_default_domain}"
      }
      dynamic "startup_probe" {
        for_each = var.bootstrap ? [] : [1]
        content {
          transport               = "HTTP"
          port                    = 8082
          path                    = "/actuator/health/liveness"
          interval_seconds        = 10
          failure_count_threshold = 30
        }
      }
      dynamic "liveness_probe" {
        for_each = var.bootstrap ? [] : [1]
        content {
          transport = "HTTP"
          port      = 8082
          path      = "/actuator/health/liveness"
        }
      }
      dynamic "readiness_probe" {
        for_each = var.bootstrap ? [] : [1]
        content {
          transport = "HTTP"
          port      = 8082
          path      = "/actuator/health/readiness"
          timeout   = 5
        }
      }
    }
  }
  depends_on = [azurerm_virtual_machine_extension.oracle, azurerm_network_security_rule.oracle_tls]
  lifecycle {
    precondition {
      condition     = var.bootstrap || (var.image != "" && length(var.database_client_cidrs) > 0)
      error_message = "Finish bootstrap and collect egress /32 IPs before deploying Investment."
    }
    precondition {
      condition     = !var.external_ingress || length(var.api_client_cidrs) > 0
      error_message = "External demo access requires at least one explicit client /32 IP."
    }
  }
}
