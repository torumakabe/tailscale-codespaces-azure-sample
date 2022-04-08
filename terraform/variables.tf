variable "prefix" {
  type = string
}

variable "admin_username" {
  type      = string
  default   = "adminuser"
  sensitive = true
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
