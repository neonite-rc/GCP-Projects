variable "project_id" {
  description = "GCP project ID"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "dr-demo"
}

variable "region" {
  description = "Primary region for the backup bucket and VM"
  type        = string
  default     = "us-east1"
}

variable "zone" {
  description = "Zone for the primary VM (within region)"
  type        = string
  default     = "us-east1-b"
}

variable "dr_region" {
  description = "DR region for the replica bucket and Cloud Run maintenance page"
  type        = string
  default     = "us-west1"
}

variable "subnet_cidr" {
  description = "CIDR range for the primary-site subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "admin_ip_cidr" {
  description = "Your workstation IP in CIDR form (e.g. 203.0.113.7/32). The ONLY address allowed to SSH."
  type        = string

  validation {
    condition     = var.admin_ip_cidr != "0.0.0.0/0"
    error_message = "Control-plane access from 0.0.0.0/0 is not allowed. Use your own IP with a /32 suffix."
  }
}

variable "machine_type" {
  description = "Machine type for the primary VM (e2-micro is free tier eligible in us-east1)"
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

variable "backup_retention_days" {
  description = "Days to keep backups before lifecycle deletion (also drives the bucket-level retention policy)"
  type        = number
  default     = 30

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 3650
    error_message = "backup_retention_days must be between 1 and 3650."
  }
}

variable "lock_backup_retention" {
  description = <<-EOT
    LOCK the bucket retention policies (is_locked = true). Once locked,
    NOBODY — including the project owner — can shorten or remove the
    retention window, ever; objects younger than the retention period are
    undeletable even by ransomware with project-owner IAM. This ALSO means
    `terraform destroy` cannot fully tear down until backups age past
    retention, so leave false while iterating on the demo and flip true
    for the real thing.
  EOT
  type        = bool
  default     = false
}

variable "backup_cron" {
  description = <<-EOT
    Cron schedule (UTC, 5 fields) for the nightly backup on the primary VM.
    This is THE RPO dial: '0 2 * * *' (daily) gives worst-case ~22h data
    loss (JOURNEY.md Day 6 measured 18h); '0 * * * *' (hourly) gets RPO
    under 1h for $0 extra on e2-micro. NOTE: the VM applies this at FIRST
    BOOT only (startup scripts don't re-run); changing it afterwards means
    editing /etc/cron.d/dr-backup on the VM or recreating it.
  EOT
  type        = string
  default     = "0 2 * * *"

  validation {
    condition     = can(regex("^[^\\s]+(\\s+[^\\s]+){4}$", var.backup_cron))
    error_message = "backup_cron must be a standard 5-field cron expression."
  }
}

variable "rpo_max_hours" {
  description = "RPO threshold in hours — the freshness check alerts past this"
  type        = number
  default     = 24
}

variable "freshness_check_cron" {
  description = "Cron schedule for the backup freshness check (runs AFTER the 02:00 UTC backup window)"
  type        = string
  default     = "0 3 * * *"
}

variable "restore_drill_cron" {
  description = "Cron schedule for the weekly automated restore drill (Sunday 05:00 UTC default — after backup + replication windows)"
  type        = string
  default     = "0 5 * * 0"
}

variable "alert_email" {
  description = "Email address for RPO-breach alerts"
  type        = string
}

variable "enable_dns" {
  description = <<-EOT
    Create the Cloud DNS failover zone and the alert-driven failover
    automation.

    A REGISTERED DOMAIN IS NOT REQUIRED. A Cloud DNS zone is
    authoritative for its own name, so the zone's nameservers answer
    queries for it directly:

      dig @ns-cloud-a1.googledomains.com app.<your-zone>

    That is enough to demonstrate and measure failover end to end.
    Registering a domain is only needed for real-world public
    resolution (so users type a name instead of querying the
    nameserver directly).
  EOT
  type        = bool
  default     = false
}

variable "dns_name" {
  description = <<-EOT
    DNS name for the managed zone, with trailing dot (e.g.
    dr-demo.example.com.).

    The public record lives one level below this (www.<dns_name>) because
    a CNAME cannot exist at a zone apex.
  EOT
  type        = string
  default     = ""
}

variable "dns_failover_role_id" {
  description = <<-EOT
    Fully-qualified id of the custom project role granting the DNS failover
    function record-set write access (e.g.
    "projects/my-project/roles/drFailoverDnsAdmin").

    Leave empty to skip the binding — the failover function then cannot
    change DNS, and the zone's records are managed by Terraform alone.

    See terraform/modules/dns/variables.tf for how to create the role and
    why the predefined alternatives do not work.
  EOT
  type        = string
  default     = ""
}

variable "dr_domain" {
  description = <<-EOT
    Domain for the DR site (used for the optional Cloud Run domain
    mapping). NOT required for DNS failover — the failover target is
    the standby's *.a.run.app hostname, which needs no domain at all.
    Only set this if you own a real domain and want the standby served
    from a vanity hostname.
  EOT
  type        = string
  default     = ""
}

variable "enable_domain_mapping" {
  description = <<-EOT
    Map a real domain to the Cloud Run DR service (requires the domain
    to be verified in Google Search Console). Off by default: it is a
    cosmetic extra, not part of the failover path. The failover
    function points DNS at the standby's *.a.run.app hostname, which
    works without any domain.
  EOT
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to all resources"
  type        = map(string)
  default = {
    project     = "gcp-hybrid-dr"
    environment = "portfolio"
    managed-by  = "terraform"
  }
}

variable "billing_account_id" {
  description = <<-EOT
    Billing account ID for the optional monthly budget alert (empty =
    skip). Find it in Billing console or `gcloud billing accounts list`.
    Requires the Billing API enabled and billing.admin on the account.
  EOT
  type        = string
  default     = ""
}

variable "monthly_budget_amount" {
  description = "Monthly budget in the billing account's currency for the billing alert (thresholds at 50%/90%/100%)"
  type        = number
  default     = 5
}

variable "budget_notify" {
  description = <<-EOT
    Send budget-threshold notifications to this project's monitoring
    channels (email + the failover Pub/Sub topic), instead of only
    recording the thresholds.

    Off by default because the Cloud Billing Budget API rejects the
    `allUpdatesRule` field outright on some accounts:
      "Invalid JSON payload received. Unknown name \"allUpdatesRule\"
       at 'budget': Cannot find field."
    (measured on both v1 and v1beta1, for every payload variant.)

    With it off, the budget still records thresholds and still notifies
    the billing account's default IAM recipients (Billing Account
    Administrators) — it is a weaker guardrail, not a broken one.
  EOT
  type        = bool
  default     = false
}

variable "billing_currency" {
  description = <<-EOT
    Currency of the billing budget. MUST match the billing account's
    currency — a mismatch is rejected with a bare "Request contains an
    invalid argument" (HTTP 400) from the Cloud Billing Budget API.
    Find yours with:
      gcloud beta billing accounts describe ACCOUNT_ID
  EOT
  type        = string
  default     = "USD"

  validation {
    condition     = contains(["USD", "INR", "EUR", "GBP", "JPY", "AUD", "CAD"], var.billing_currency)
    error_message = "billing_currency must be a supported ISO 4217 code (USD, INR, EUR, GBP, JPY, AUD, CAD)."
  }
}
