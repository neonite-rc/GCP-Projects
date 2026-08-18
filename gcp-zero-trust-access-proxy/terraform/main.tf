# ============================================================================
# Primary region (always deployed)
# ============================================================================

module "network" {
  source = "./modules/network"

  network_name   = var.network_name
  subnet_name    = "vpn-subnet-${var.primary_region.region}"
  subnet_cidr    = var.primary_region.subnet_cidr
  region         = var.primary_region.region
  admin_ip_cidr  = var.admin_ip_cidr
  wireguard_port = var.wireguard_port
}

module "vpn_server" {
  source = "./modules/vpn-server"

  instance_name  = var.primary_region.instance_name
  machine_type   = var.machine_type
  zone           = var.primary_region.zone
  boot_disk_size = var.boot_disk_size
  network_id     = module.network.network_id
  subnet_id      = module.network.subnet_id
  wireguard_port = var.wireguard_port
  wireguard_cidr = var.primary_region.wireguard_cidr
  ssh_public_key = var.ssh_public_key
  ssh_user       = var.ssh_user
  startup_script = file("${path.module}/../src/scripts/startup.sh")

  region                 = var.primary_region.region
  enable_auto_shutdown   = var.enable_auto_shutdown
  auto_shutdown_cron     = var.auto_shutdown_cron
  auto_shutdown_timezone = var.auto_shutdown_timezone

  duckdns_domain = var.duckdns_domain
  duckdns_token  = var.duckdns_token
}

# ============================================================================
# Additional regions (for_each over additional_regions map)
# ============================================================================

locals {
  active_regions = { for k, v in var.additional_regions : k => v if v.enabled }
}

# One /28 subnet per additional region
resource "google_compute_subnetwork" "region" {
  for_each = local.active_regions

  name                     = "vpn-subnet-${each.key}"
  ip_cidr_range            = each.value.subnet_cidr
  region                   = each.value.region
  network                  = module.network.network_id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.1
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# WireGuard UDP firewall rule per additional region
resource "google_compute_firewall" "allow_wireguard_region" {
  for_each = local.active_regions

  name    = "${var.network_name}-allow-wireguard-${each.key}"
  network = module.network.network_id

  allow {
    protocol = "udp"
    ports    = [tostring(var.wireguard_port)]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["wireguard"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# SSH firewall rule per additional region
resource "google_compute_firewall" "allow_ssh_region" {
  for_each = local.active_regions

  name    = "${var.network_name}-allow-ssh-${each.key}"
  network = module.network.network_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.admin_ip_cidr]
  target_tags   = ["wireguard"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# VPN server instance per additional region
module "vpn_server_region" {
  source   = "./modules/vpn-server"
  for_each = local.active_regions

  instance_name  = each.value.instance_name
  machine_type   = var.machine_type
  zone           = each.value.zone
  boot_disk_size = var.boot_disk_size
  network_id     = module.network.network_id
  subnet_id      = google_compute_subnetwork.region[each.key].id
  wireguard_port = var.wireguard_port
  wireguard_cidr = each.value.wireguard_cidr
  ssh_public_key = var.ssh_public_key
  ssh_user       = var.ssh_user
  startup_script = file("${path.module}/../src/scripts/startup.sh")

  region                 = each.value.region
  enable_auto_shutdown   = var.enable_auto_shutdown
  auto_shutdown_cron     = var.auto_shutdown_cron
  auto_shutdown_timezone = var.auto_shutdown_timezone

  duckdns_domain = ""
  duckdns_token  = ""
}

# ============================================================================
# DNS: Cloud DNS weighted routing across all regions
# ============================================================================

module "dns" {
  source = "./modules/dns"
  count  = var.dns_zone_name != "" ? 1 : 0

  project_id   = var.project_id
  zone_name    = var.dns_zone_name
  domain       = var.dns_domain
  primary_ip   = module.vpn_server.public_ip
  secondary_ip = ""
}

# ============================================================================
# Serverless functions (wake-on-demand + health check)
# ============================================================================

resource "google_storage_bucket" "functions" {
  name                        = "${var.project_id}-functions"
  location                    = var.primary_region.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

module "wake_vpn" {
  source = "./modules/cloud-function"

  project_id  = var.project_id
  name        = "wake-vpn"
  source_dir  = "${path.module}/../src/functions/wake-vpn"
  entry_point = "wake_vpn"
  runtime     = "python311"
  bucket_name = google_storage_bucket.functions.name
  region      = var.primary_region.region
  public      = true

  iam_roles = ["roles/compute.instanceAdmin.v1"]

  env_vars = {
    WAKE_TOKEN    = var.wake_token
    PROJECT_ID    = var.project_id
    ZONE          = var.primary_region.zone
    INSTANCE_NAME = var.primary_region.instance_name
  }
}

# Build comma-separated list of all region hosts for health check
locals {
  all_region_hosts = join(",", concat(
    [var.primary_region.instance_name],
    [for r in values(local.active_regions) : r.instance_name]
  ))
  all_region_keys = join(",", concat(
    [var.primary_region.region],
    [for k in keys(local.active_regions) : k]
  ))
}

module "vpn_health" {
  source = "./modules/cloud-function"

  project_id  = var.project_id
  name        = "vpn-health"
  source_dir  = "${path.module}/../src/functions/vpn-health"
  entry_point = "vpn_health"
  runtime     = "python311"
  bucket_name = google_storage_bucket.functions.name
  region      = var.primary_region.region
  public      = true

  iam_roles = ["roles/monitoring.metricWriter"]

  env_vars = {
    DUCKDNS_HOSTNAME = var.duckdns_domain != "" ? "${var.duckdns_domain}.duckdns.org" : ""
    SSH_PORT         = "22"
    WG_PORT          = tostring(var.wireguard_port)
    PROJECT_ID       = var.project_id
    PRIMARY_HOST     = "${var.primary_region.instance_name}.${var.primary_region.region}.internal"
    REGION_HOSTS     = local.all_region_hosts
    REGION_KEYS      = local.all_region_keys
  }
}

# Cloud Scheduler: trigger health check every 5 minutes
resource "google_cloud_scheduler_job" "vpn_health" {
  name     = "vpn-health-check"
  region   = var.primary_region.region
  schedule = "*/5 * * * *"

  http_target {
    http_method = "GET"
    uri         = module.vpn_health.url

    oidc_token {
      service_account_email = module.vpn_health.service_account_email
    }
  }
}

# ============================================================================
# Moved blocks (backward compatibility with existing state)
# ============================================================================

moved {
  from = module.vpn_server_secondary
  to   = module.vpn_server_region["us-west1"]
}

moved {
  from = google_compute_subnetwork.secondary
  to   = google_compute_subnetwork.region["us-west1"]
}

moved {
  from = google_compute_firewall.allow_wireguard_secondary
  to   = google_compute_firewall.allow_wireguard_region["us-west1"]
}
