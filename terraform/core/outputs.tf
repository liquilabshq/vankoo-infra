output "suffix" {
  value = random_string.suffix.result
}

output "ocr_endpoint" {
  value = azurerm_cognitive_account.ocr.endpoint
}

output "ocr_key" {
  value     = azurerm_cognitive_account.ocr.primary_access_key
  sensitive = true
}

output "environment_id" {
  value = azapi_resource.environment.id
}

output "environment_default_domain" {
  # try(): justo después de un import el recurso aún no tiene salida.
  value = try(azapi_resource.environment.output.properties.defaultDomain, null)
}

# Debe decir WorkloadProfiles. Si dice Express, Azure ignoró el modo pedido.
output "environment_mode" {
  value = try(azapi_resource.environment.output.properties.environmentMode, null)
}
