output "zone_name" {
  value = google_dns_managed_zone.vpn.name
}

output "fqdn" {
  value = "vpn.${var.domain}"
}

output "name_servers" {
  value = google_dns_managed_zone.vpn.name_servers
}
