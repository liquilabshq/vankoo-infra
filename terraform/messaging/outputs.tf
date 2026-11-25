# Dirección del endpoint de Kafka del namespace (siempre el puerto 9093, con TLS).
output "kafka_bootstrap_server" {
  value = "${azurerm_eventhub_namespace.vankoo.name}.servicebus.windows.net:9093"
}

# Cadena de conexión de cada servicio. Es la contraseña SASL: el usuario es
# siempre el texto literal $ConnectionString.
output "kafka_connection_strings" {
  value     = { for client, rule in azurerm_eventhub_namespace_authorization_rule.clients : client => rule.primary_connection_string }
  sensitive = true
}
