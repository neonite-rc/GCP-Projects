# ---------------------------------------------------------------------------
# Hybrid Cloud Disaster Recovery — root composition.
#
# Primary site: e2-micro VM (simulated on-prem) with Flask app + SQLite.
# DR site: Cloud Run maintenance page (scale-to-zero, $0/mo until failover).
# Backup: nightly to CMEK-encrypted Cloud Storage, cross-region replication.
# Monitoring: RPO-breach alerts via Cloud Function + log-based metric.
# ---------------------------------------------------------------------------

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  required_services = [
    "compute.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "storage-api.googleapis.com",
    "storagetransfer.googleapis.com",
    "dns.googleapis.com",
    "cloudfunctions.googleapis.com",
    "pubsub.googleapis.com",
    "cloudscheduler.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    # NOTE: the Cloud KMS service name is "cloudkms.googleapis.com".
    # "kms.googleapis.com" does not resolve — enabling it fails with
    # SERVICE_CONFIG_NOT_FOUND_OR_PERMISSION_DENIED and the CMEK keys
    # then cannot be created.
    "cloudkms.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    # Eventarc delivers the Pub/Sub tick to the Cloud Functions. The
    # function resource creates the Eventarc trigger, so the API must be
    # enabled BEFORE the function — otherwise the trigger fails validation
    # with "Eventarc API has not been used in project ... before".
    "eventarc.googleapis.com",
  ]

  # File contents delivered via instance metadata (single source of truth)
  app_py          = file("${path.module}/../src/app/app.py")
  nginx_conf      = file("${path.module}/../src/app/nginx-app.conf")
  backup_script   = file("${path.module}/../src/scripts/backup.sh")
  verify_script   = file("${path.module}/../src/scripts/verify-backup.sh")
  startup_script  = file("${path.module}/../src/scripts/startup.sh")
  redeploy_script = file("${path.module}/../src/scripts/redeploy.sh")
}

resource "google_project_service" "required" {
  for_each = toset(local.required_services)

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}

module "primary" {
  source = "./modules/primary-site"

  network_name       = "${var.name_prefix}-primary-vpc"
  subnet_name        = "${var.name_prefix}-primary-subnet"
  subnet_cidr        = var.subnet_cidr
  region             = var.region
  zone               = var.zone
  admin_ip_cidr      = var.admin_ip_cidr
  instance_name      = "${var.name_prefix}-primary"
  machine_type       = var.machine_type
  boot_disk_size     = var.boot_disk_size
  ssh_user           = var.ssh_user
  ssh_public_key     = var.ssh_public_key
  startup_script     = local.startup_script
  app_py             = local.app_py
  nginx_conf         = local.nginx_conf
  backup_script      = local.backup_script
  verify_script      = local.verify_script
  redeploy_script    = local.redeploy_script
  backup_bucket_name = module.backup.backup_bucket_name
  backup_cron        = var.backup_cron
  labels             = var.labels

  depends_on = [google_project_service.required]
}

module "backup" {
  source = "./modules/backup"

  project_id            = var.project_id
  region                = var.region
  dr_region             = var.dr_region
  name_prefix           = var.name_prefix
  primary_sa_email      = module.primary.service_account_email
  backup_retention_days = var.backup_retention_days
  lock_backup_retention = var.lock_backup_retention
  rpo_max_hours         = var.rpo_max_hours
  freshness_check_cron  = var.freshness_check_cron
  restore_drill_cron    = var.restore_drill_cron
  drill_source_dir      = "${path.module}/../src/functions/restore-drill"
  retirement_source_dir = "${path.module}/../src/functions/key-version-retirement"
  alert_email           = var.alert_email
  function_source_dir   = "${path.module}/../src/functions/backup-trigger"
  labels                = var.labels

  depends_on = [google_project_service.required]
}

module "dr_site" {
  source = "./modules/dr-site"

  project_id            = var.project_id
  dr_region             = var.dr_region
  name_prefix           = var.name_prefix
  domain                = var.dr_domain
  enable_domain_mapping = var.enable_domain_mapping
  labels                = var.labels

  depends_on = [google_project_service.required]
}

module "dns" {
  source = "./modules/dns"
  count  = var.enable_dns ? 1 : 0

  project_id           = var.project_id
  dns_name             = var.dns_name
  zone_name            = "${var.name_prefix}-dr-zone"
  name_prefix          = var.name_prefix
  region               = var.region
  primary_ip           = module.primary.public_ip
  public_record_name   = "www.${var.dns_name}"
  primary_target_name  = "primary.${var.dns_name}"
  dr_target            = module.dr_site.failover_target
  dr_health_url        = "${module.dr_site.service_uri}/health"
  dns_failover_role_id = var.dns_failover_role_id
  function_source_dir  = "${path.module}/../src/functions/dns-failover"
  labels               = var.labels

  depends_on = [google_project_service.required]
}
