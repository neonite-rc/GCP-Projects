variable "instance_name" {
  description = "Name of the VPN server VM"
  type        = string
}

variable "machine_type" {
  description = "Machine type"
  type        = string
}

variable "zone" {
  description = "Zone for the VM"
  type        = string
}

variable "boot_disk_size" {
  description = "Boot disk size in GB"
  type        = number
}

variable "network_id" {
  description = "VPC network ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID"
  type        = string
}

variable "wireguard_port" {
  description = "UDP port for WireGuard"
  type        = number
}

variable "wireguard_cidr" {
  description = "CIDR for the WireGuard tunnel network"
  type        = string
}

variable "ssh_user" {
  description = "SSH username"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key material"
  type        = string
}

variable "startup_script" {
  description = "Startup script contents"
  type        = string
}

variable "region" {
  description = "Region for the instance schedule policy (must match the VM's region)"
  type        = string
}

variable "enable_auto_shutdown" {
  description = "Attach a nightly stop schedule to the VM"
  type        = bool
}

variable "auto_shutdown_cron" {
  description = "Cron schedule for the nightly VM stop"
  type        = string
}

variable "auto_shutdown_timezone" {
  description = "IANA time zone for the shutdown schedule"
  type        = string
}

variable "duckdns_domain" {
  description = "DuckDNS subdomain (empty = disabled)"
  type        = string
  default     = ""
}

variable "duckdns_token" {
  description = "DuckDNS API token"
  type        = string
  default     = ""
  sensitive   = true
}
