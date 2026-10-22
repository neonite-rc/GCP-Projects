variable "project_id" {
  description = "GCP project ID (used for globally-unique bucket names and service agents)"
  type        = string
}

variable "region" {
  description = "Primary region — backup bucket + KMS key location"
  type        = string
}

variable "dr_region" {
  description = "DR region — replica bucket + KMS key location"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "primary_sa_email" {
  description = "Email of the primary VM's service account (gets write-only access to the backup bucket)"
  type        = string
}

variable "backup_retention_days" {
  description = "Days to keep backups before lifecycle deletion"
  type        = number
}

variable "rpo_max_hours" {
  description = "RPO threshold in hours — the freshness check alerts past this"
  type        = number
}

variable "freshness_check_cron" {
  description = "Cron schedule for the backup freshness check (runs AFTER the 02:00 UTC backup window)"
  type        = string
  default     = "0 3 * * *"
}

variable "restore_drill_cron" {
  description = "Cron schedule for the automated restore drill (weekly; must land after a backup + replication window)"
  type        = string
  default     = "0 5 * * 0"
}

variable "drill_source_dir" {
  description = "Path to src/functions/restore-drill (zipped by archive_file)"
  type        = string
}

variable "retirement_source_dir" {
  description = "Path to src/functions/key-version-retirement (zipped by archive_file)"
  type        = string
}

variable "key_retirement_cron" {
  description = <<-EOT
    Cron schedule (UTC) for the CMEK key version retirement sweep. Monthly
    by default — rotation is every 90 days, so a monthly sweep is far more
    than often enough to keep the billed version count at 1 per key.
  EOT
  type        = string
  default     = "0 4 1 * *"
}

variable "replication_start_time" {
  description = "UTC start time (hours) for the daily cross-region replication run"
  type        = number
  default     = 4
}

variable "alert_email" {
  description = "Email address for RPO-breach alerts"
  type        = string
}

variable "function_source_dir" {
  description = "Path to the backup-trigger Cloud Function source"
  type        = string
}

variable "lock_backup_retention" {
  description = "Lock the bucket retention policies permanently (see root variable docs for the destroy tradeoff)"
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to labelable resources (buckets, KMS keys, topics)"
  type        = map(string)
  default     = {}
}
