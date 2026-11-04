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

output "profile_db_host" {
  value = azurerm_postgresql_flexible_server.profile.fqdn
}

output "profile_db_name" {
  value = azurerm_postgresql_flexible_server_database.profile.name
}

output "profile_db_username" {
  value = local.admin_username
}

output "profile_db_password" {
  value     = random_password.profile_db.result
  sensitive = true
}

output "invoicing_db_connection_string" {
  value     = local.invoicing_db_connection_string
  sensitive = true
}
