output "public_ip" {
  value = google_compute_instance.vpn.network_interface[0].access_config[0].nat_ip
}

output "internal_ip" {
  value = google_compute_instance.vpn.network_interface[0].network_ip
}

output "instance_name" {
  value = google_compute_instance.vpn.name
}
