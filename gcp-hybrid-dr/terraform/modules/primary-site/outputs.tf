output "public_ip" {
  description = "Static public IP of the primary VM (DNS failover primary target)"
  value       = google_compute_address.primary_ip.address
}

output "internal_ip" {
  description = "Internal IP of the primary VM"
  value       = google_compute_instance.primary.network_interface[0].network_ip
}

output "service_account_email" {
  description = "Email of the primary VM's dedicated service account"
  value       = google_service_account.primary.email
}

output "network_name" {
  description = "Name of the custom VPC"
  value       = google_compute_network.vpc.name
}
