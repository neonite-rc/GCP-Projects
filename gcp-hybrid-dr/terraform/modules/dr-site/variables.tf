variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "dr_region" {
  description = "Region for the DR Cloud Run service (different from primary region)"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "maintenance_image" {
  description = <<-EOT
    Container image for the maintenance page. If null, defaults to the
    image path inside the Artifact Registry repo this module creates —
    build & push it first:
      gcloud builds submit src/dr-site \
        --tag <dr_region>-docker.pkg.dev/<project>/<prefix>-dr-site/maintenance:v1
  EOT
  type        = string
  default     = null
}

variable "domain" {
  description = "Domain the DR site serves under when a real domain is mapped (no trailing dot)"
  type        = string
}

variable "enable_domain_mapping" {
  description = <<-EOT
    Map the domain to the Cloud Run service. Requires a REAL registered
    domain verified in Google Search Console — off by default because the
    demo uses a placeholder domain (registration is out of scope/cost).
  EOT
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to labelable resources (Cloud Run service, Artifact Registry repo)"
  type        = map(string)
  default     = {}
}
