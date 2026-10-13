# Variables comunes a todas las capas. Es igual en las cuatro: si cambias
# una, cambia las demás.

variable "resource_group_name" {
  description = "Grupo de recursos donde vive todo Vankoo. Lo crea el dueño de la suscripción, no Terraform."
  type        = string
  default     = "liquilabs-vankoo"
}

variable "location" {
  description = "Región de los recursos. La política de la suscripción solo permite algunas; centralus tiene PostgreSQL B1ms."
  type        = string
  default     = "centralus"
}

variable "tfstate_storage_account" {
  description = "Cuenta de almacenamiento del estado. La exportan los scripts como TF_VAR_tfstate_storage_account."
  type        = string
}
