variable "dni_provider" {
  description = "Fuente que consulta la función: eldni (web real) o fake (datos de demostración, sin salir a internet)."
  type        = string
  default     = "eldni"

  validation {
    condition     = contains(["eldni", "fake"], var.dni_provider)
    error_message = "dni_provider debe ser eldni o fake."
  }
}

variable "service_plan_sku" {
  description = "SKU del plan. Y1 = consumo (pago por uso). Si la suscripción no tiene cuota de Y1 en la región, probar B1 (plan fijo, ~13 USD/mes)."
  type        = string
  default     = "Y1"
}
