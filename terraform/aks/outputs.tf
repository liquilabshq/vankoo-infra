output "cluster_name" {
  value = azurerm_kubernetes_cluster.vankoo.name
}

output "node_resource_group" {
  description = "Grupo que crea AKS para los nodos, discos e IP del balanceador."
  value       = azurerm_kubernetes_cluster.vankoo.node_resource_group
}

output "acr_login_server" {
  value = data.terraform_remote_state.base.outputs.acr_login_server
}
