variable "dni_provider" {
  description = "Fuente que consulta la función: eldni (web real) o fake (datos de demostración, sin salir a internet)."
  type        = string
  default     = "eldni"

  validation {
    condition     = contains(["eldni", "fake"], var.dni_provider)
    error_message = "dni_provider debe ser eldni o fake."
  }
}
