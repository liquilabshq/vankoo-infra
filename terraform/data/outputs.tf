output "iam_db_host" {
  value = azurerm_postgresql_flexible_server.iam.fqdn
}

output "iam_db_name" {
  value = azurerm_postgresql_flexible_server_database.iam.name
}

output "iam_db_username" {
  value = local.admin_username
}

output "iam_db_password" {
  value     = random_password.iam_db.result
  sensitive = true
}

output "invoicing_db_connection_string" {
  value     = local.invoicing_db_connection_string
  sensitive = true
}
