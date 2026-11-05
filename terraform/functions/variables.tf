variable "dni_provider" {
  description = <<-EOT
    Fuente que consulta la función: eldni (web real) o fake (datos de demostración, sin salir a internet).
    Por defecto fake: eldni.com responde 404 a las peticiones que salen de Azure (Central US), aunque desde
    Perú funciona, así que en la nube la fuente real no es utilizable. Para probarla de nuevo (otra región,
    otra IP de salida): -var dni_provider=eldni.
  EOT
  type        = string
  default     = "fake"

  validation {
    condition     = contains(["eldni", "fake"], var.dni_provider)
    error_message = "dni_provider debe ser eldni o fake."
  }
}
