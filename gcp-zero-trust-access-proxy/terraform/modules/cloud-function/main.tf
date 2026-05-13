data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/tmp/${var.name}.zip"
}

resource "google_storage_bucket_object" "source" {
  name   = "${var.name}/${data.archive_file.source.output_md5}.zip"
  bucket = var.bucket_name
  source = data.archive_file.source.output_path
}

resource "google_service_account" "this" {
  account_id   = "${var.name}-sa"
  display_name = "${var.name} Cloud Function"
}

resource "google_project_iam_member" "roles" {
  count   = length(var.iam_roles)
  project = var.project_id
  role    = var.iam_roles[count.index]
  member  = "serviceAccount:${google_service_account.this.email}"
}

resource "google_cloudfunctions2_function" "this" {
  name     = var.name
  location = var.region

  build_config {
    runtime     = var.runtime
    entry_point = var.entry_point
    source {
      storage_source {
        bucket = var.bucket_name
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    max_instance_count    = 1
    available_memory      = var.memory
    timeout_seconds       = var.timeout_seconds
    available_cpu         = var.cpu
    service_account_email = google_service_account.this.email
    environment_variables = var.env_vars
  }
}

resource "google_cloud_run_service_iam_member" "public" {
  count    = var.public ? 1 : 0
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
