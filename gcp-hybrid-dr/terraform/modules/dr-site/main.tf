# ---------------------------------------------------------------------------
# DR site — Cloud Run maintenance page, scale-to-zero.
# Costs $0/mo while the primary is healthy: no traffic → zero instances.
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "dr_site" {
  location      = var.dr_region
  repository_id = "${var.name_prefix}-dr-site"
  description   = "Maintenance-page image for the DR site"
  format        = "DOCKER"
  labels        = var.labels

  # Keep only recent images — registry storage is billable past 0.5 GB
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }
}

# Zero-role runtime SA: serving a static page needs no GCP API access at
# all. Matches the portfolio baseline (unlike the primary VM's SA, which
# carries one documented bucket-level write grant).
resource "google_service_account" "dr_site" {
  account_id   = "${var.name_prefix}-dr-site-sa"
  display_name = "DR maintenance page (no API access)"
}

locals {
  image = coalesce(
    var.maintenance_image,
    "${var.dr_region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dr_site.repository_id}/maintenance:v1"
  )
}

resource "google_cloud_run_v2_service" "dr_site" {
  name     = "${var.name_prefix}-dr-maintenance"
  location = var.dr_region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = var.labels

  template {
    service_account = google_service_account.dr_site.email

    scaling {
      min_instance_count = 0 # scale to zero — the whole cost story
      max_instance_count = 2 # a maintenance page needs no fleet
    }

    containers {
      image = local.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "128Mi"
        }
        cpu_idle = true # CPU only during requests (cheapest tier)
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 3
      }
    }
  }
}

# Public by design: a maintenance page users get failed over TO must be
# anonymously reachable. It is static, read-only, and runs as a zero-role SA.
resource "google_cloud_run_v2_service_iam_member" "public" {
  location = google_cloud_run_v2_service.dr_site.location
  name     = google_cloud_run_v2_service.dr_site.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Domain mapping: gives the Cloud Run service stable Google-front-end A
# records (216.239.3x.21) that the DNS failover policy can point at.
# Gated: requires a real, Search-Console-verified domain (out of scope for
# the demo budget — documented in docs/01-architecture.md).
resource "google_cloud_run_domain_mapping" "dr_site" {
  count    = var.enable_domain_mapping ? 1 : 0
  location = var.dr_region
  name     = "app.${var.domain}"

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloud_run_v2_service.dr_site.name
  }
}
