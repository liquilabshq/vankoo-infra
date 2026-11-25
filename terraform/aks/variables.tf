# Tamaño del clúster. La suscripción tiene 6 vCPU por región y 4 por familia en
# centralus: el pool del sistema usa los 4 de DSv3 (dos D2s_v3) y el pool extra
# 2 de DSv4 (un D2s_v4).

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

# Con la VM de Oracle de Container Apps borrada (24 nov 2026) quedan libres los
# 4 vCPU de la familia DSv4 y 2 de la cuota regional: un nodo D2s_v4 más.
variable "extra_node_vm_size" {
  description = "Tamaño del pool extra (otra familia, por la cuota de DSv3)."
  type        = string
  default     = "Standard_D2s_v4"
}

variable "extra_node_count" {
  description = "Nodos del pool extra; 0 lo quita."
  type        = number
  default     = 1
}
