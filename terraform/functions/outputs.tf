output "function_app_name" {
  description = "Va en la variable AZURE_FUNCTIONAPP_NAME del repo de la función."
  value       = azurerm_function_app_flex_consumption.dni_verification.name
}

output "verify_dni_url" {
  description = "Va en DNI_VERIFICATION_URL de profile-service."
  value       = "https://${azurerm_function_app_flex_consumption.dni_verification.default_hostname}/api/verify-dni"
}

output "health_url" {
  value = "https://${azurerm_function_app_flex_consumption.dni_verification.default_hostname}/api/health"
}
