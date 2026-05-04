variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "network_name" {
  description = "Name of the custom VPC"
  type        = string
  default     = "vpn-vpc"
}

variable "admin_ip_cidr" {
  description = "Your home/office IP in CIDR form (e.g. 203.0.113.7/32). SSH is ONLY allowed from here."
  type        = string

  validation {
    condition     = var.admin_ip_cidr != "0.0.0.0/0"
    error_message = "SSH from 0.0.0.0/0 is not allowed. Use your own IP with a /32 suffix (see JOURNEY.md Day 3)."
  }
}

variable "wireguard_port" {
  description = "UDP port for WireGuard"
  type        = number
  default     = 51820
}

variable "machine_type" {
  description = "Machine type (e2-micro is free-tier eligible in us-east1/us-west1)"
  type        = string
  default     = "e2-micro"
}

variable "boot_disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 10
}

variable "ssh_user" {
  description = "SSH username for admin access"
  type        = string
  default     = "admin"
}

variable "ssh_public_key" {
  description = "SSH public key material for the admin user"
  type        = string
}

variable "enable_auto_shutdown" {
  description = "Attach a nightly stop schedule to each VM"
  type        = bool
  default     = true
}

variable "auto_shutdown_cron" {
  description = "Cron schedule for the nightly VM stop"
  type        = string
  default     = "0 1 * * *"
}

variable "auto_shutdown_timezone" {
  description = "IANA time zone for the shutdown schedule"
  type        = string
  default     = "Etc/UTC"
}

variable "duckdns_domain" {
  description = "DuckDNS subdomain for the primary server. Leave empty to disable."
  type        = string
  default     = ""
}

variable "duckdns_token" {
  description = "DuckDNS API token"
  type        = string
  default     = ""
  sensitive   = true
}

variable "wake_token" {
  description = "Secret token for wake-on-demand Cloud Function authentication"
  type        = string
  sensitive   = true
}

# --- Primary region (always deployed) ---

variable "primary_region" {
  description = "Primary region config {region, zone, subnet_cidr, wireguard_cidr}"
  type = object({
    region         = string
    zone           = string
    subnet_cidr    = string
    wireguard_cidr = string
    instance_name  = string
  })
  default = {
    region         = "us-east1"
    zone           = "us-east1-b"
    subnet_cidr    = "10.0.0.0/28"
    wireguard_cidr = "10.200.200.0/24"
    instance_name  = "wireguard-vpn"
  }
}

# --- Additional regions (for_each, opt-in) ---

variable "additional_regions" {
  description = <<EOT
Map of additional regions to deploy VPN servers.
Each entry: {region, zone, subnet_cidr, wireguard_cidr, instance_name, enabled}
Disable a region by setting enabled = false.
EOT
  type = map(object({
    region         = string
    zone           = string
    subnet_cidr    = string
    wireguard_cidr = string
    instance_name  = string
    enabled        = bool
  }))
  default = {
    "us-west1" = {
      region         = "us-west1"
      zone           = "us-west1-a"
      subnet_cidr    = "10.0.1.0/28"
      wireguard_cidr = "10.200.1.0/24"
      instance_name  = "wireguard-vpn-w2"
      enabled        = true
    }
    "asia-south1" = {
      region         = "asia-south1"
      zone           = "asia-south1-a"
      subnet_cidr    = "10.0.2.0/28"
      wireguard_cidr = "10.200.2.0/24"
      instance_name  = "wireguard-vpn-mumbai"
      enabled        = false
    }
    "asia-east1" = {
      region         = "asia-east1"
      zone           = "asia-east1-a"
      subnet_cidr    = "10.0.3.0/28"
      wireguard_cidr = "10.200.3.0/24"
      instance_name  = "wireguard-vpn-taiwan"
      enabled        = false
    }
    "asia-southeast1" = {
      region         = "asia-southeast1"
      zone           = "asia-southeast1-a"
      subnet_cidr    = "10.0.4.0/28"
      wireguard_cidr = "10.200.4.0/24"
      instance_name  = "wireguard-vpn-singapore"
      enabled        = false
    }
    "europe-west1" = {
      region         = "europe-west1"
      zone           = "europe-west1-b"
      subnet_cidr    = "10.0.5.0/28"
      wireguard_cidr = "10.200.5.0/24"
      instance_name  = "wireguard-vpn-belgium"
      enabled        = false
    }
    "europe-west4" = {
      region         = "europe-west4"
      zone           = "europe-west4-a"
      subnet_cidr    = "10.0.6.0/28"
      wireguard_cidr = "10.200.6.0/24"
      instance_name  = "wireguard-vpn-netherlands"
      enabled        = false
    }
    "europe-west2" = {
      region         = "europe-west2"
      zone           = "europe-west2-a"
      subnet_cidr    = "10.0.7.0/28"
      wireguard_cidr = "10.200.7.0/24"
      instance_name  = "wireguard-vpn-london"
      enabled        = true
    }
    "asia-northeast1" = {
      region         = "asia-northeast1"
      zone           = "asia-northeast1-a"
      subnet_cidr    = "10.0.8.0/28"
      wireguard_cidr = "10.200.8.0/24"
      instance_name  = "wireguard-vpn-tokyo"
      enabled        = true
    }
    "southamerica-east1" = {
      region         = "southamerica-east1"
      zone           = "southamerica-east1-a"
      subnet_cidr    = "10.0.9.0/28"
      wireguard_cidr = "10.200.9.0/24"
      instance_name  = "wireguard-vpn-saopaulo"
      enabled        = false
    }
  }
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name (leave empty to disable)"
  type        = string
  default     = ""
}

variable "dns_domain" {
  description = "DNS domain for the VPN (e.g. 'example.com')"
  type        = string
  default     = ""
}
