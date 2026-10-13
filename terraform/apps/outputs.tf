output "gateway_url" {
  value = "https://${azurerm_container_app.gateway.ingress[0].fqdn}"
}

output "gateway_scalar_url" {
  value = "https://${azurerm_container_app.gateway.ingress[0].fqdn}/scalar"
}
