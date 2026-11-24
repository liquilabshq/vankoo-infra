# Tamaño del clúster. La suscripción tiene 6 vCPU por región y 4 por familia
# DSv3 en centralus; la VM de Oracle del despliegue en Container Apps (D2s_v4,
# 2 vCPU) cuenta aunque esté desasignada. Quedan 4 vCPU: dos nodos de 2.

variable "node_vm_size" {
  description = "Tamaño de los nodos. D2s_v3: 2 vCPU y 8 GB, x86 (las imágenes son linux/amd64)."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "node_count" {
  description = "Número de nodos del pool del sistema."
  type        = number
  default     = 2
}
