output "endpoint" {
  description = "Endpoint de Communication Services, para la API REST de correo."
  value       = "https://${azurerm_communication_service.vankoo.hostname}"
}

output "connection_string" {
  description = "Cadena de conexión (endpoint y clave). Va al Secret vankoo-secrets como ACS_CONNECTION_STRING."
  value       = azurerm_communication_service.vankoo.primary_connection_string
  sensitive   = true
}

output "sender_address" {
  description = "Remitente verificado del dominio administrado."
  value       = "${var.sender_username}@${azurerm_email_communication_service_domain.azure_managed.from_sender_domain}"
}
