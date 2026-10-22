output "primary_ip" {
  description = "Static public IP of the primary VM (DNS failover primary target)"
  value       = module.primary.public_ip
}

output "dr_service_uri" {
  description = "URL of the DR Cloud Run maintenance page"
  value       = module.dr_site.service_uri
}

output "backup_bucket" {
  description = "Name of the primary backup bucket"
  value       = module.backup.backup_bucket_name
}

output "replica_bucket" {
  description = "Name of the cross-region replica bucket"
  value       = module.backup.replica_bucket_name
}

output "freshness_function" {
  description = "Name of the backup freshness Cloud Function"
  value       = module.backup.freshness_function_name
}

output "rpo_breach_alert" {
  description = "Name of the RPO-breach alert policy"
  value       = module.backup.alert_policy_name
}

output "restore_drill_function" {
  description = "Name of the weekly automated restore-drill Cloud Function"
  value       = module.backup.restore_drill_function_name
}

output "restore_drill_alert" {
  description = "Name of the restore-drill-failure alert policy"
  value       = module.backup.restore_drill_alert_policy_name
}

output "dr_dashboard" {
  description = "Display name of the DR-posture Monitoring dashboard"
  value       = google_monitoring_dashboard.dr_posture.dashboard_json != null ? "${var.name_prefix} — DR posture" : null
}

output "dns_failover_function" {
  description = "Name of the DNS failover function (null when enable_dns = false)"
  value       = var.enable_dns ? module.dns[0].failover_function_name : null
}

output "ssh_command" {
  description = "Command to SSH into the primary VM"
  value       = "gcloud compute ssh ${var.name_prefix}-primary --zone=${var.zone} --project=${var.project_id}"
}

output "dns_name_servers" {
  description = "Name servers to set at the registrar (null when enable_dns = false)"
  value       = var.enable_dns ? module.dns[0].name_servers : null
}

output "dns_name" {
  description = "The managed zone's DNS name, with a trailing dot (null when enable_dns = false)"
  value       = var.enable_dns ? var.dns_name : null
}

output "dns_public_record" {
  description = <<-EOT
    The public FQDN that failover moves, with a trailing dot — the name
    to query and to pass to disaster-drill.sh --dns-name (null when
    enable_dns = false).
  EOT
  value       = var.enable_dns ? "www.${var.dns_name}" : null
}

output "project_id" {
  description = "The GCP project everything lives in"
  value       = var.project_id
}

output "dr_standby_host" {
  description = "Hostname of the DR standby (the failover target), with a trailing dot"
  value       = var.enable_dns ? module.dr_site.failover_target : null
}
