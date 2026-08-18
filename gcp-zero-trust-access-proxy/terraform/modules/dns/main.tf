resource "google_dns_managed_zone" "vpn" {
  name        = var.zone_name
  dns_name    = "${var.domain}."
  description = "DNS zone for multi-region VPN (weighted routing)"
}

# A record for the primary VPN server
resource "google_dns_record_set" "vpn_primary" {
  managed_zone = google_dns_managed_zone.vpn.name
  name         = "vpn.${var.domain}."
  type         = "A"
  ttl          = var.ttl
  rrdatas      = [var.primary_ip]
}

# Weighted routing record for the secondary VPN server (when multi-region enabled)
resource "google_dns_record_set" "vpn_secondary" {
  count        = var.secondary_ip != "" ? 1 : 0
  managed_zone = google_dns_managed_zone.vpn.name
  name         = "vpn.${var.domain}."
  type         = "A"
  ttl          = var.ttl
  rrdatas      = [var.secondary_ip]
}
