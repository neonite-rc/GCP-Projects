output "url" {
  description = "Function URL"
  value       = google_cloudfunctions2_function.this.url
}

output "name" {
  description = "Function name"
  value       = google_cloudfunctions2_function.this.name
}

output "service_account_email" {
  description = "Function service account email"
  value       = google_service_account.this.email
}
