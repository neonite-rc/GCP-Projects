variable "network_name" {
  description = "Name of the custom VPC"
  type        = string
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
}

variable "region" {
  description = "Region for the subnet"
  type        = string
}

variable "admin_ip_cidr" {
  description = "CIDR allowed to SSH"
  type        = string
}

variable "wireguard_port" {
  description = "UDP port for WireGuard"
  type        = number
}
