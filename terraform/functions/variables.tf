variable "dni_provider" {
  description = <<-EOT
    Fuente que consulta la función: eldni (scraping de la web), apiperu (API de terceros con token) o
    fake (datos de demostración, sin salir a internet).
    Por defecto fake: eldni.com responde 404 a las peticiones que salen de Azure (Central US), aunque desde
    Perú funciona, así que en la nube el scraping no es utilizable. Para una verificación real en la nube:
    -var dni_provider=apiperu junto con TF_VAR_apiperu_token. Para probar eldni de nuevo (otra región, otra
    IP de salida): -var dni_provider=eldni.
  EOT
  type        = string
  default     = "fake"

  validation {
    condition     = contains(["eldni", "apiperu", "fake"], var.dni_provider)
    error_message = "dni_provider debe ser eldni, apiperu o fake."
  }
}

variable "apiperu_token" {
  description = <<-EOT
    Token Bearer de API Perú (https://apiperu.pe). Solo hace falta con dni_provider = apiperu.
    Es un secreto: pásalo con la variable de entorno TF_VAR_apiperu_token y no lo escribas en ningún
    archivo versionado. Terraform lo guarda en el estado remoto (cuenta de almacenamiento del grupo).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}
