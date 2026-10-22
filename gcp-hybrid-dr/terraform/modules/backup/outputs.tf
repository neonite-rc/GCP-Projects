output "backup_bucket_name" {
  description = "Name of the primary backup bucket (CMEK, versioned, 30-day lifecycle)"
  value       = google_storage_bucket.backup.name
}

output "replica_bucket_name" {
  description = "Name of the cross-region Nearline replica bucket"
  value       = google_storage_bucket.replica.name
}

output "backup_kms_key_id" {
  description = "CMEK key protecting the backup bucket"
  value       = google_kms_crypto_key.backup.id
}

output "freshness_function_name" {
  description = "Name of the backup freshness Cloud Function"
  value       = google_cloudfunctions2_function.freshness.name
}

output "alert_policy_name" {
  description = "Name of the RPO-breach alert policy"
  value       = google_monitoring_alert_policy.rpo_breach.display_name
}

output "restore_drill_function_name" {
  description = "Name of the automated restore-drill Cloud Function"
  value       = google_cloudfunctions2_function.restore_drill.name
}

output "restore_drill_alert_policy_name" {
  description = "Name of the restore-drill-failure alert policy"
  value       = google_monitoring_alert_policy.restore_drill_fail.display_name
}
