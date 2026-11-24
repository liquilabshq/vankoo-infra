# Capa aks: el clúster de Kubernetes (Azure Kubernetes Service) donde corre todo
# Vankoo con los manifiestos de k8s/ (overlay azure). Es independiente de las
# capas de Container Apps (data, messaging, apps): solo lee el sufijo de core y el
# registro de imágenes de base, y no los modifica. Los datos viven dentro del
# clúster (StatefulSets con discos de Azure), no en las bases administradas.
#
# Coste: el plano de control Free no cobra; cada nodo cobra mientras está
# encendido. scripts/aks/aks-stop.sh apaga los nodos sin perder los discos y
# scripts/aks/aks-destroy.sh borra el clúster entero.

data "azurerm_resource_group" "vankoo" {
  name = var.resource_group_name
}

data "terraform_remote_state" "core" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "core.tfstate"
  }
}

data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = var.tfstate_storage_account
    container_name       = "tfstate"
    key                  = "base.tfstate"
  }
}

data "azurerm_container_registry" "acr" {
  name                = data.terraform_remote_state.base.outputs.acr_name
  resource_group_name = data.azurerm_resource_group.vankoo.name
}

locals {
  suffix = data.terraform_remote_state.core.outputs.suffix
}

resource "azurerm_kubernetes_cluster" "vankoo" {
  name                = "vankoo-aks-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.vankoo.name
  location            = var.location
  dns_prefix          = "vankoo-${local.suffix}"
  sku_tier            = "Free"

  # Sin versión fija: Azure elige la versión por defecto de la región, y sin
  # canal de actualización automática (es el valor por defecto).

  default_node_pool {
    name            = "system"
    vm_size         = var.node_vm_size
    node_count      = var.node_count
    os_disk_size_gb = 64
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure CNI Overlay con el plano de datos de Cilium: los pods toman IPs de una
  # red privada propia (no gastan direcciones de una VNet) y Cilium hace cumplir
  # las NetworkPolicies de k8s/base/network/network-policy.yaml.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
  }

  tags = {
    "vankoo-managed-by" = "terraform"
    "vankoo-layer"      = "aks"
  }
}

# Los nodos bajan las imágenes del ACR con su propia identidad (equivale a
# `az aks update --attach-acr`): no hace falta ningún secreto de registro.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = data.azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.vankoo.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# Tercer nodo, de otra familia: la cuota DSv3 (4 vCPU) ya la ocupan los dos del
# pool del sistema, y la DSv4 quedó libre. Las bases, Kafka, Axon, Argo CD y el
# monitoreo no caben con holgura en 2 nodos de 8 GB.
resource "azurerm_kubernetes_cluster_node_pool" "extra" {
  count                 = var.extra_node_count > 0 ? 1 : 0
  name                  = "extra"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.vankoo.id
  vm_size               = var.extra_node_vm_size
  node_count            = var.extra_node_count
  os_disk_size_gb       = 64
  mode                  = "User"

  tags = {
    "vankoo-managed-by" = "terraform"
    "vankoo-layer"      = "aks"
  }
}
