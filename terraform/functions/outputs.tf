output "function_app_name" {
  description = "Va en la variable AZURE_FUNCTIONAPP_NAME del repo de la función."
  value       = azurerm_linux_function_app.dni_verification.name
}

output "verify_dni_url" {
  description = "Va en DNI_VERIFICATION_URL de profile-service."
  value       = "https://${azurerm_linux_function_app.dni_verification.default_hostname}/api/verify-dni"
}

output "health_url" {
  value = "https://${azurerm_linux_function_app.dni_verification.default_hostname}/api/health"
}
