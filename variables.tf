variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "ssh_key_fingerprint" {
  description = "Fingerprint of the SSH key uploaded to DigitalOcean"
  type        = string
}

variable "region" {
  description = "DigitalOcean region for the droplet"
  type        = string
  default     = "sgp1"
}

variable "size" {
  description = "Droplet size slug"
  type        = string
  default     = "s-1vcpu-512mb-10gb"
}

variable "droplet_name" {
  description = "Droplet name"
  type        = string
  default     = "xray-vpn"
}

variable "xray_port" {
  description = "Xray server port"
  type        = number
  default     = 443
}

variable "xray_server_name" {
  description = "Xray Reality server name (SNI)"
  type        = string
  default     = "www.cloudflare.com"
}

variable "allowed_ssh_ips" {
  description = "List of IP addresses/CIDR blocks allowed to SSH"
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for remote-exec (optional, defaults to ~/.ssh/id_rsa)"
  type        = string
  default     = "~/.ssh/id_rsa"
  sensitive   = true
}

variable "ssh_private_key" {
  description = "SSH private key content (alternative to ssh_private_key_path, for CI/CD)"
  type        = string
  default     = ""
  sensitive   = true
}
