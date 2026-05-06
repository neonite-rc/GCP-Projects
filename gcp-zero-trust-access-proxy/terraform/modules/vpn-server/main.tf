# Dedicated identity with zero IAM roles and zero scopes: even if the VM is
# compromised, it cannot call any GCP API (unlike the default compute SA).
resource "google_service_account" "vpn" {
  account_id   = "${var.instance_name}-sa"
  display_name = "WireGuard VPN server (no API access)"
}

# Nightly stop schedule. On the free tier with ephemeral IP, a stopped VM
# costs $0. DuckDNS keeps the hostname current across reboots.
resource "google_compute_resource_policy" "auto_shutdown" {
  count  = var.enable_auto_shutdown ? 1 : 0
  name   = "${var.instance_name}-nightly-stop"
  region = var.region

  instance_schedule_policy {
    time_zone = var.auto_shutdown_timezone

    vm_stop_schedule {
      schedule = var.auto_shutdown_cron
    }
  }
}

resource "google_compute_instance" "vpn" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["wireguard"]

  resource_policies = google_compute_resource_policy.auto_shutdown[*].self_link

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = var.boot_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = var.network_id
    subnetwork = var.subnet_id

    #trivy:ignore:AVD-GCP-0031
    access_config {}
  }

  # WireGuard needs IP forwarding at the instance level to NAT client traffic
  #trivy:ignore:AVD-GCP-0043
  can_ip_forward = true

  # OS Login deliberately off: it grants IAM-based SSH to anyone with the
  # right project role. A single provisioned key + blocked project keys is
  # a smaller trust surface for a single-admin appliance.
  #trivy:ignore:AVD-GCP-0036
  metadata = {
    ssh-keys               = "${var.ssh_user}:${var.ssh_public_key}"
    block-project-ssh-keys = "true"
    enable-oslogin         = "false"
    wg-port                = tostring(var.wireguard_port)
    wg-cidr                = var.wireguard_cidr
    duckdns-domain         = var.duckdns_domain
    duckdns-token          = var.duckdns_token
  }

  metadata_startup_script = var.startup_script

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    automatic_restart = true
  }

  # Dedicated SA with no roles + no scopes: zero GCP API access
  service_account {
    email  = google_service_account.vpn.email
    scopes = []
  }
}
