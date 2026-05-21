# main.tf — On-demand VPN server with Tailscale exit node
#
# Architecture:
#   vpn up   → enable_server=true  → creates preemptible instance (~$0.003/hr)
#   vpn down → enable_server=false → destroys it ($0)
#
# One instance at a time, in whichever region you choose.
# Tailscale handles key exchange, NAT traversal, and exit node routing.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project" {
  type        = string
  description = "GCP project ID"
}

variable "active_region" {
  type        = string
  description = "GCP region to deploy in"
  default     = "asia-south1"
}

variable "enable_server" {
  type        = bool
  description = "true = create server (vpn up), false = destroy (vpn down)"
  default     = false
}

variable "machine_type" {
  type    = string
  default = "e2-micro"
}

variable "ts_authkey" {
  type        = string
  description = "Tailscale reusable auth key (from login.tailscale.com/admin/settings/keys)"
  default     = ""
  sensitive   = true
}

# ── Zone lookup ──────────────────────────────────────────────────────────────
locals {
  zone_map = {
    "us-east1"           = "us-east1-b"
    "us-west1"           = "us-west1-a"
    "asia-south1"        = "asia-south1-a"
    "asia-east1"         = "asia-east1-a"
    "asia-southeast1"    = "asia-southeast1-a"
    "europe-west1"       = "europe-west1-b"
    "europe-west4"       = "europe-west4-a"
    "europe-west2"       = "europe-west2-a"
    "asia-northeast1"    = "asia-northeast1-a"
    "southamerica-east1" = "southamerica-east1-a"
  }
  zone = lookup(local.zone_map, var.active_region, "${var.active_region}-a")
}

provider "google" {
  project = var.project
  region  = var.active_region
  zone    = local.zone
}

# ── Network (always present — free) ──────────────────────────────────────────
resource "google_compute_network" "vpn" {
  name                    = "vpn-net"
  auto_create_subnetworks = true
}

resource "google_compute_firewall" "vpn_allow" {
  name    = "vpn-allow-tailscale"
  network = google_compute_network.vpn.name

  allow {
    protocol = "udp"
    ports    = ["41641"] # Tailscale
  }
  allow {
    protocol = "udp"
    ports    = ["51820"] # WireGuard (backup)
  }
  allow {
    protocol = "tcp"
    ports    = ["8080"] # Dashboard
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["vpn-exit-node"]
}

# ── Startup script ────────────────────────────────────────────────────────────
locals {
  startup_script = <<-SCRIPT
    #!/bin/bash
    set -e

    # Install Tailscale
    if ! command -v tailscale &>/dev/null; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # IP forwarding (required for exit node)
    cat > /etc/sysctl.d/99-tailscale.conf <<'SYSCTL'
    net.ipv4.ip_forward = 1
    net.ipv6.conf.all.forwarding = 1
    SYSCTL
    sysctl -p /etc/sysctl.d/99-tailscale.conf

    # Auth: try GCE metadata, fall back to manual
    TS_AUTHKEY=""
    TS_AUTHKEY=$(curl -sf -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ts-authkey" 2>/dev/null || true)

    if [ -n "$TS_AUTHKEY" ]; then
      tailscale up \
        --authkey="$TS_AUTHKEY" \
        --advertise-exit-node \
        --hostname="vpn-${var.active_region}" \
        --accept-routes
    else
      tailscale up \
        --advertise-exit-node \
        --hostname="vpn-${var.active_region}" \
        --accept-routes
    fi

    echo "Tailscale exit node ready: vpn-${var.active_region}"
  SCRIPT
}

# ── Compute instance (on/off) ────────────────────────────────────────────────
resource "google_compute_instance" "vpn" {
  count        = var.enable_server ? 1 : 0
  name         = "vpn-${var.active_region}"
  machine_type = var.machine_type
  zone         = local.zone
  tags         = ["vpn-exit-node"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
    }
  }

  network_interface {
    network = google_compute_network.vpn.name
    access_config {}
  }

  metadata = {
    ts-authkey     = var.ts_authkey
    startup-script = local.startup_script
  }

  # Preemptible = 80% cheaper, fine for VPN (just re-up if reclaimed)
  scheduling {
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
  }

  # Zero-scope SA: VM can't call any GCP API
  service_account {
    scopes = []
  }

  lifecycle {
    create_before_destroy = false
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "server_ip" {
  value       = length(google_compute_instance.vpn) > 0 ? google_compute_instance.vpn[0].network_interface[0].access_config[0].nat_ip : ""
  description = "Public IP of the VPN server (empty when down)"
}

output "server_status" {
  value = var.enable_server ? "running in ${var.active_region}" : "down"
}

output "all_regions" {
  value = length(google_compute_instance.vpn) > 0 ? { (var.active_region) = { public_ip = google_compute_instance.vpn[0].network_interface[0].access_config[0].nat_ip, instance_name = "vpn-${var.active_region}" } } : {}
}
