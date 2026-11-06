variable "resource_group_name" {
  type    = string
  default = "liquilabs-vankoo"
}
variable "location" {
  type    = string
  default = "centralus"
}
variable "tfstate_storage_account" { type = string }
variable "investment_ssh_public_key" {
  description = "Public SSH key only, never the private key."
  type        = string
}
variable "vm_size" {
  description = "Match the deployed academic VM; review capacity and cost before overriding."
  type        = string
  default     = "Standard_D2s_v4"
}
variable "vnet_cidr" {
  type    = string
  default = "10.40.0.0/16"
}
variable "subnet_cidr" {
  type    = string
  default = "10.40.1.0/24"
}
variable "database_client_cidrs" {
  description = "Exact /32 egress IPs of Investment, collected after bootstrap. No Internet-wide access."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for cidr in var.database_client_cidrs : can(cidrnetmask(cidr)) && endswith(cidr, "/32")])
    error_message = "Only explicit IPv4 /32 addresses are allowed."
  }
}
variable "bootstrap" {
  description = "First apply uses an internal sample app to discover outbound IPs before allowing Oracle access."
  type        = bool
  default     = true
}
variable "image" {
  type    = string
  default = ""
}
variable "external_ingress" {
  description = "Optional temporary API access for the owner; restricted to api_client_cidrs. Internal by default."
  type        = bool
  default     = false
}
variable "api_client_cidrs" {
  type    = list(string)
  default = []
  validation {
    condition     = alltrue([for cidr in var.api_client_cidrs : can(cidrnetmask(cidr)) && endswith(cidr, "/32")])
    error_message = "Only explicit IPv4 /32 addresses are allowed."
  }
}
