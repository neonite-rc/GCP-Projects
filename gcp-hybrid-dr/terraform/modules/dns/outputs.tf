output "name_servers" {
  description = "Delegate the domain to these at the registrar"
  value       = google_dns_managed_zone.dr.name_servers
}

output "zone_name" {
  description = "Managed zone resource name"
  value       = google_dns_managed_zone.dr.name
}

output "active_record_name" {
  description = "FQDN of the single active A record the failover function rewrites"
  value       = google_dns_record_set.active.name
}

output "failover_notification_channel_id" {
  description = "Pub/Sub notification channel to attach to the primary_down alert policy"
  value       = google_monitoring_notification_channel.failover_pubsub.id
}

output "failover_function_name" {
  description = "Name of the DNS failover Cloud Function"
  value       = google_cloudfunctions2_function.dns_failover.name
}
