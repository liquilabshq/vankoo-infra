variable "data_location" {
  description = "Dónde guarda ACS los datos de los mensajes. Es una zona geográfica, no una región."
  type        = string
  default     = "United States"
}

variable "sender_username" {
  description = "Parte local del remitente. El dominio administrado trae DoNotReply."
  type        = string
  default     = "DoNotReply"
}
