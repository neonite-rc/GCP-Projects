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

# Rule 1: WireGuard from anywhere (UDP only, single port)
resource "google_compute_firewall" "allow_wireguard" {
  name    = "${var.network_name}-allow-wireguard"
  network = google_compute_network.vpc.id

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

# Rule 2: SSH from admin IP only
resource "google_compute_firewall" "allow_ssh_admin" {
  name    = "${var.network_name}-allow-ssh-admin"
  network = google_compute_network.vpc.id

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

# Rule 3: internal traffic within the VPC
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.network_name}-allow-internal"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
}

# Rule 4: explicit deny-all ingress at lowest priority (GCP default is implicit
# deny; this makes the posture visible and logs blocked attempts)
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
