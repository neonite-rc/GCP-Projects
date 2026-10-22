output "service_name" {
  description = "Name of the DR Cloud Run service"
  value       = google_cloud_run_v2_service.dr_site.name
}

output "service_uri" {
  description = "Direct *.run.app URL of the DR maintenance page"
  value       = google_cloud_run_v2_service.dr_site.uri
}

output "failover_target" {
  description = <<-EOT
    Hostname of the DR standby, suitable for a CNAME record: the
    Cloud Run service's *.a.run.app name (no scheme, no path, with a
    trailing dot so it is a valid DNS name).

    This is the failover target the DNS module points the public record
    at during an incident. A NAME rather than an IP, because Google's
    Cloud Run front-end IPs rotate — a CNAME to run.app always resolves
    to the live front end.

    Derived from the service's real URI rather than assembled from its
    name: the URI carries the region and hash suffix that make the
    hostname unique, and guessing them would produce a name that
    resolves to the wrong (or no) service.

    NOTE: `replace()` in Terraform does NOT treat its arguments as
    regular expressions — it matches literal substrings. Using it with
    "^https://" silently leaves the scheme in place, and Cloud DNS then
    rejects the CNAME with "Invalid value for ... rdata[0]". `trimprefix`
    and `trimsuffix` are the correct functions here.
  EOT
  value = format(
    "%s.",
    trimsuffix(trimprefix(google_cloud_run_v2_service.dr_site.uri, "https://"), "/")
  )
}

output "image" {
  description = "Container image the service runs (build & push before first apply)"
  value       = local.image
}

output "artifact_repo" {
  description = "Artifact Registry repository for the maintenance image"
  value       = google_artifact_registry_repository.dr_site.repository_id
}
