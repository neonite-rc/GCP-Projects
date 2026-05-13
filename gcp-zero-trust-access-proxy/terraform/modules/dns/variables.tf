variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "zone_name" {
  description = "Cloud DNS managed zone name (e.g. 'vpn-example-com')"
  type        = string
}

variable "domain" {
  description = "DNS domain (e.g. 'example.com')"
  type        = string
}

variable "primary_ip" {
  description = "Public IP of the primary VPN server"
  type        = string
}

variable "secondary_ip" {
  description = "Public IP of the secondary VPN server (empty = single-region)"
  type        = string
  default     = ""
}

variable "ttl" {
  description = "DNS record TTL in seconds"
  type        = number
  default     = 60
}
