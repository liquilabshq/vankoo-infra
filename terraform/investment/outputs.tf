output "investment_url" { value = "https://${azurerm_container_app.investment.ingress[0].fqdn}" }
output "investment_outbound_ips" { value = azurerm_container_app.investment.outbound_ip_addresses }
output "oracle_hostname" { value = azurerm_public_ip.database.fqdn }
output "oracle_vm_name" { value = azurerm_linux_virtual_machine.database.name }
output "bootstrap_mode" { value = var.bootstrap }
