variable "network_name" {
  description = "Name of the custom VPC for the primary site"
  type        = string
}

variable "subnet_name" {
  description = "Name of the primary-site subnet"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the primary-site subnet"
  type        = string
}

variable "region" {
  description = "Region for the subnet and VM"
  type        = string
}

variable "zone" {
  description = "Zone for the primary VM"
  type        = string
}

variable "admin_ip_cidr" {
  description = "Admin IP in CIDR form — the only source allowed to SSH"
  type        = string
}

variable "instance_name" {
  description = "Name of the primary web/app VM"
  type        = string
}

variable "machine_type" {
  description = "Machine type (e2-micro is free-tier eligible in us-east1)"
  type        = string
}

variable "boot_disk_size" {
  description = "Boot disk size in GB"
  type        = number
}

variable "ssh_user" {
  description = "SSH username for admin access"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key material for the admin user"
  type        = string
}

variable "startup_script" {
  description = "Contents of the first-boot provisioning script"
  type        = string
}

variable "app_py" {
  description = "Contents of the Flask app, delivered via instance metadata"
  type        = string
}

variable "nginx_conf" {
  description = "Contents of the nginx site config, delivered via instance metadata"
  type        = string
}

variable "backup_script" {
  description = "Contents of backup.sh, delivered via instance metadata"
  type        = string
}

variable "verify_script" {
  description = "Contents of verify-backup.sh, delivered via instance metadata"
  type        = string
}

variable "backup_bucket_name" {
  description = "Name of the GCS backup bucket the VM writes nightly backups to"
  type        = string
}

variable "backup_cron" {
  description = "Cron schedule (UTC) for backup.sh — delivered via metadata, applied at first boot by startup.sh. The RPO dial."
  type        = string
  default     = "0 2 * * *"
}

variable "labels" {
  description = "Labels applied to labelable resources (VM, disks)"
  type        = map(string)
  default     = {}
}
