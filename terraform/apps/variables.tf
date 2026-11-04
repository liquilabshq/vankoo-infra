variable "images" {
  description = "Imagen completa de cada servicio en el registro. La escribe scripts/azure/build-push.sh en images.auto.tfvars."
  type        = map(string)
}

variable "min_replicas" {
  description = "Réplicas mínimas. 1 evita arranques en frío durante la expo; 0 deja que escalen a cero."
  type        = number
  default     = 1
}

variable "allowed_origins" {
  description = "Orígenes que el gateway acepta por CORS, separados por comas (la web y la landing)."
  type        = string
  default     = "*"
}

variable "web_app_url" {
  description = "URL base de la web de la MYPE. IAM la usa para el enlace de recuperar contraseña."
  type        = string
  default     = "http://localhost:5173"
}

variable "jwt_expiration_days" {
  description = "Días de validez de los JWT que emite IAM."
  type        = number
  default     = 7
}

# Credenciales del bucket de S3 que comparten Invoicing (PDF de las facturas) y
# Profile (documentos y fotos). No van a git: se pasan como TF_VAR_aws_* desde la
# terminal o con --env-file.
variable "aws_region" {
  type = string
}

variable "aws_s3_bucket" {
  type = string
}

variable "aws_access_key_id" {
  type      = string
  sensitive = true
}

variable "aws_secret_access_key" {
  type      = string
  sensitive = true
}

# Verificación automática del DNI del inversor en Profile (Azure Function
# vankoo-dni-verification-…, que no gestiona este Terraform). Vacías = apagada:
# el KYC del inversor queda manual.
variable "dni_verification_url" {
  description = "URL del endpoint verify-dni de la función. Vacía desactiva la verificación."
  type        = string
  default     = ""
}

variable "dni_verification_key" {
  description = "Clave de la función (x-functions-key). Vacía si la función no la pide."
  type        = string
  sensitive   = true
  default     = ""
}
