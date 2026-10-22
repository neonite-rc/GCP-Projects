# ---------------------------------------------------------------------------
# Network — custom-mode VPC, one small subnet, flow logs at low sampling
# ---------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false # custom mode: auto-mode creates subnets in every region
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "subnet" {
  name                     = var.subnet_name
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  # Low sampling keeps log volume inside the Cloud Logging free tier
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Firewall — least privilege
# ---------------------------------------------------------------------------

# Rule 1: HTTP from anywhere. This is a public website AND the target of the
# Cloud DNS failover health checks (Google probes arrive from Google source
# ranges, users from anywhere). 443 stays closed: no TLS certificate exists
# without a registered domain (see docs/03-security.md).
resource "google_compute_firewall" "allow_http" {
  name    = "${var.network_name}-allow-http"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["dr-primary"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Rule 2: SSH from the admin IP only — 0.0.0.0/0 is rejected by a root
# variable validation block (lesson carried over from the VPN project).
resource "google_compute_firewall" "allow_ssh_admin" {
  name    = "${var.network_name}-allow-ssh-admin"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.admin_ip_cidr]
  target_tags   = ["dr-primary"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Disable GCP's default SSH rule.
#
# `default-allow-ssh` is created with every new VPC and allows tcp:22 from
# 0.0.0.0/0 — i.e. the internet — to EVERY instance in the network. It
# completely defeats the admin-IP-only SSH rule above (GCP evaluates all
# rules; an allow from anywhere still permits the connection).
#
# It only bites on a CUSTOM-mode VPC. In auto-mode there is no default
# rule at all, which is why the previous version of this project never
# noticed it. Disabling it explicitly makes the "SSH is admin-IP-only"
# claim true rather than aspirational — and it is exactly the kind of
# default-safety issue a portfolio reviewer should be able to see
# addressed.
#
# The rule is NOT created by Terraform — GCP creates it with the VPC, so
# Terraform can only take it over. The `import` block that does that
# lives in the ROOT module (terraform/imports.tf): Terraform only
# allows import blocks in the root module, and a module-level one
# fails `terraform init` with "An import block was detected in
# \"module.primary\". Import blocks are only allowed in the root
# module."
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "disable_default_ssh" {
  name    = "default-allow-ssh"
  network = google_compute_network.vpc.id

  # `disabled = true` is the supported way to turn off a default rule.
  # (An empty source_ranges block does NOT work — the rule still exists
  # and the API still lets it match; it must be explicitly disabled.)
  disabled = true
  priority = 65535

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = []

  description = "Disabled by Terraform: the default rule allows SSH from 0.0.0.0/0, which would bypass the admin-IP-only rule."
}

# Rule 3: explicit deny-all ingress at lowest priority (GCP default is
# implicit deny; this makes the posture visible and logs blocked attempts)
resource "google_compute_firewall" "deny_all_ingress" {
  name     = "${var.network_name}-deny-all-ingress"
  network  = google_compute_network.vpc.id
  priority = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Identity — dedicated service account
# ---------------------------------------------------------------------------

# Near-zero-role SA: its ONLY grant is roles/storage.objectCreator on the
# backup bucket (bucket-level, bound in the backup module). Documented
# deviation from the portfolio's "zero-role SA" baseline: the nightly backup
# must write to GCS, and objectCreator is write-only — the VM cannot list,
# read, overwrite or delete backups, so a compromised primary cannot destroy
# its own recovery path. No project-level roles, no scopes beyond storage.
resource "google_service_account" "primary" {
  account_id   = "${var.instance_name}-sa"
  display_name = "DR primary site VM (write-only to backup bucket)"
}

# ---------------------------------------------------------------------------
# VM — e2-micro, Shielded VM, static IP (DNS failover needs a stable target)
# ---------------------------------------------------------------------------

resource "google_compute_address" "primary_ip" {
  name   = "${var.instance_name}-ip"
  region = var.region
}

resource "google_compute_instance" "primary" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["dr-primary"]
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = var.boot_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id

    # This VM simulates the customer-facing on-prem site: it must be
    # internet-reachable (it IS the primary the DNS health check watches).
    # Risk accepted and mitigated: only 80/tcp is open publicly, SSH is
    # admin-IP-only, and the SA is write-only to a single bucket.
    #trivy:ignore:AVD-GCP-0031
    access_config {
      nat_ip = google_compute_address.primary_ip.address
    }
  }

  # OS Login deliberately off: it grants IAM-based SSH to anyone with the
  # right project role. A single provisioned key + blocked project keys is
  # a smaller trust surface for a single-admin demo appliance.
  #trivy:ignore:AVD-GCP-0036
  metadata = {
    ssh-keys               = "${var.ssh_user}:${var.ssh_public_key}"
    block-project-ssh-keys = "true"
    enable-oslogin         = "false"

    # App + backup tooling delivered via metadata so src/ stays the single
    # source of truth (startup.sh fetches these at first boot).
    app-py        = var.app_py
    nginx-conf    = var.nginx_conf
    backup-script = var.backup_script
    verify-script = var.verify_script
    backup-bucket = var.backup_bucket_name
    backup-cron   = var.backup_cron
  }

  metadata_startup_script = var.startup_script

  # `gcloud compute ssh` APPENDS the caller's key to the instance's
  # ssh-keys metadata. That means every time an admin SSHes in, the
  # metadata drifts from what Terraform wrote — and because the
  # ssh-keys value is part of the instance fingerprint, Terraform would
  # REPLACE the VM to "fix" it. Replacing the primary site because
  # someone logged in is not acceptable behaviour for a DR system.
  #
  # Ignoring the change keeps the provisioned key in place (the drift is
  # additive, never a removal) and stops the churn.
  lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    automatic_restart = true
  }

  # Dedicated SA; storage-rw scope is the ceiling, actual power comes from
  # the single bucket-level IAM binding (scopes cap, IAM grants).
  service_account {
    email  = google_service_account.primary.email
    scopes = ["https://www.googleapis.com/auth/devstorage.read_write"]
  }
}
