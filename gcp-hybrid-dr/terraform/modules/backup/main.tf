# GCS service agent — encrypts/decrypts bucket objects with the CMEK keys
data "google_storage_project_service_account" "gcs" {
  project = var.project_id
}

# Storage Transfer Service agent — runs the cross-region replication job
data "google_storage_transfer_project_service_account" "sts" {
  project = var.project_id
}

# ---------------------------------------------------------------------------
# KMS — CMEK for both buckets. A key must live in the same location as the
# bucket it protects, hence one keyring per region.
#
# NOTE: KMS keyrings/keys are never physically deleted (GCP design).
# `terraform destroy` only removes them from state; key versions cost
# $0.06/mo each until destroyed — see docs/02-cost-analysis.md.
#
# ON ROTATION AND COST — measured, not assumed:
#
# A key version is billed while it is Enabled, Disabled, OR Scheduled for
# destruction. Rotating a key creates a new primary version but does NOT
# disable or destroy the old one, and nothing disables it automatically.
#
# Measured on a scratch key with a 1-day rotation period:
#
#   after one rotation:  version 1 ENABLED, version 2 ENABLED
#                        -> BOTH billed, $0.12/mo for a key that has
#                           rotated exactly once
#
# `destroy_scheduled_duration` is NOT the fix, and this is easy to get
# wrong: it only controls how long a version stays in
# DESTROY_SCHEDULED once something has explicitly destroyed it. It does
# not schedule anything on rotation. (It was already 30 days on these
# keys — the default — and the leak happened anyway.)
#
# The fix is the `key-version-retirement` function in
# src/functions/key-version-retirement: it runs monthly, finds versions
# that are no longer primary and are older than the backup retention
# window, and destroys them. Without it, 90-day rotation adds a version
# every 90 days FOREVER: ~13 versions per key after a year, $0.78/mo
# per key, $1.56/mo for two keys — against a $0.12/mo claim in the cost
# table. A slow, invisible cost leak in a project whose whole pitch is
# cost control.
#
# The retirement window must be longer than the backup retention window,
# because destroying a key version makes the data it encrypted
# UNREADABLE. The oldest backup that must still be restorable is
# `backup_retention_days` old, so a superseded version has to outlive
# that.
# ---------------------------------------------------------------------------

resource "google_kms_key_ring" "primary" {
  name     = "${var.name_prefix}-backup-keyring"
  location = var.region
}

resource "google_kms_key_ring" "dr" {
  name     = "${var.name_prefix}-backup-keyring-dr"
  location = var.dr_region
}

resource "google_kms_crypto_key" "backup" {
  name            = "${var.name_prefix}-backup-key"
  key_ring        = google_kms_key_ring.primary.id
  rotation_period = "7776000s" # 90 days

  # How long a version stays in DESTROY_SCHEDULED once the retirement
  # function has destroyed it. 30 days is the GCP default and gives a
  # window in which a mistaken destruction can still be reversed.
  destroy_scheduled_duration = "2592000s"

  purpose = "ENCRYPT_DECRYPT"
  labels  = var.labels
}

resource "google_kms_crypto_key" "replica" {
  name            = "${var.name_prefix}-backup-key-dr"
  key_ring        = google_kms_key_ring.dr.id
  rotation_period = "7776000s" # 90 days

  destroy_scheduled_duration = "2592000s"

  purpose = "ENCRYPT_DECRYPT"
  labels  = var.labels
}

# The GCS service agent performs the server-side encryption, so IT (not the
# uploader) needs the key. Root cause of the Day 4 debugging story — see
# JOURNEY.md and docs/05-troubleshooting.md.
resource "google_kms_crypto_key_iam_member" "gcs_backup_key" {
  crypto_key_id = google_kms_crypto_key.backup.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_kms_crypto_key_iam_member" "gcs_replica_key" {
  crypto_key_id = google_kms_crypto_key.replica.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# ---------------------------------------------------------------------------
# Backup bucket (primary region, Standard class — written nightly, read by
# verification; Nearline's 30-day minimum + retrieval fee loses the math
# here, see JOURNEY.md Day 7)
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "backup" {
  name     = "${var.project_id}-${var.name_prefix}-backups"
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = var.labels

  # Demo teardown convenience: allows `terraform destroy` on a non-empty,
  # versioned bucket. Production would set this false + add retention locks.
  force_destroy = true

  # Object versioning: recover from accidental deletion/overwrite — and the
  # last line of defence if backup credentials are ever abused.
  versioning {
    enabled = true
  }

  # Bucket-level retention: even a principal with storage.admin IAM cannot
  # delete objects younger than the retention window. Closes the gap left
  # by object-level protections (the write-only VM SA): an attacker with
  # PROJECT-level IAM could otherwise delete the bucket itself.
  # is_locked (var.lock_backup_retention) makes the window permanent for
  # EVERYONE — flip only when you accept that destroy needs backups to age
  # out first.
  retention_policy {
    # retention_period is a NUMBER of SECONDS in this provider version —
    # a string like "2592000s" is rejected with "Incorrect attribute
    # value type" at plan time.
    retention_period = var.backup_retention_days * 86400
    is_locked        = var.lock_backup_retention
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.backup.id
  }

  # Age out backups once the retention window allows deletion
  lifecycle_rule {
    condition {
      age = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }

  # Cap noncurrent-version buildup from versioning
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_backup_key]
}

# The ONLY IAM grant the primary VM's SA holds anywhere: write-only into
# this bucket. objectCreator cannot list, read, overwrite or delete — a
# compromised (e.g. ransomware'd) primary cannot destroy existing backups.
# Documented deviation from the portfolio's zero-role-SA baseline.
resource "google_storage_bucket_iam_member" "primary_writer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${var.primary_sa_email}"
}

# ---------------------------------------------------------------------------
# Replica bucket (DR region, Nearline — written once daily by the transfer
# job, read only during a regional disaster; Nearline halves storage cost
# and its 30-day minimum matches the retention window exactly)
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "replica" {
  name     = "${var.project_id}-${var.name_prefix}-backups-replica"
  location = var.dr_region

  storage_class               = "NEARLINE"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  labels                      = var.labels

  versioning {
    enabled = true
  }

  # Same bucket-level retention as the primary backup bucket — the replica
  # is the disaster copy; it deserves identical deletion protection.
  retention_policy {
    # retention_period is a NUMBER of SECONDS in this provider version.
    retention_period = var.backup_retention_days * 86400
    is_locked        = var.lock_backup_retention
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.replica.id
  }

  lifecycle_rule {
    condition {
      age = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_replica_key]
}

# ---------------------------------------------------------------------------
# Cross-region replication — Storage Transfer Service, daily.
# Evaluated alternatives (JOURNEY.md Day 3): dual-region bucket (no control
# over the second region's storage class → 2x Standard cost) and re-uploading
# twice from the VM (doubles VM egress + widens the VM's IAM). STS is
# server-side, free for GCS→GCS, and needs zero credentials on the VM.
# ---------------------------------------------------------------------------

resource "google_storage_bucket_iam_member" "sts_source_viewer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_storage_transfer_project_service_account.sts.email}"
}

resource "google_storage_bucket_iam_member" "sts_source_reader" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${data.google_storage_transfer_project_service_account.sts.email}"
}

resource "google_storage_bucket_iam_member" "sts_sink_writer" {
  bucket = google_storage_bucket.replica.name
  role   = "roles/storage.legacyBucketWriter"
  member = "serviceAccount:${data.google_storage_transfer_project_service_account.sts.email}"
}

resource "google_storage_transfer_job" "replicate" {
  description = "Daily backup replication ${google_storage_bucket.backup.name} -> ${google_storage_bucket.replica.name}"
  project     = var.project_id

  transfer_spec {
    gcs_data_source {
      bucket_name = google_storage_bucket.backup.name
    }
    gcs_data_sink {
      bucket_name = google_storage_bucket.replica.name
    }
    transfer_options {
      # Backups are immutable (timestamped names); never overwrite, never
      # propagate deletions — lifecycle rules age out each bucket separately.
      overwrite_objects_already_existing_in_sink = false
      delete_objects_unique_in_sink              = false
    }
  }

  schedule {
    schedule_start_date {
      year  = 2025
      month = 1
      day   = 1
    }
    # 04:00 UTC: 2h after the 02:00 backup window
    start_time_of_day {
      hours   = var.replication_start_time
      minutes = 0
      seconds = 0
      nanos   = 0
    }
  }

  depends_on = [
    google_storage_bucket_iam_member.sts_source_viewer,
    google_storage_bucket_iam_member.sts_source_reader,
    google_storage_bucket_iam_member.sts_sink_writer,
  ]
}

# ---------------------------------------------------------------------------
# Freshness sentinel — Scheduler -> Pub/Sub -> Cloud Function (2nd gen).
# The backup itself runs on the VM via cron (02:00 UTC); this function only
# VERIFIES freshness and raises the RPO_BREACH log the alert watches.
# Simpler honest design vs "function SSHes into the VM" — see JOURNEY.md.
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "freshness_tick" {
  name   = "${var.name_prefix}-backup-freshness-tick"
  labels = var.labels
}

resource "google_cloud_scheduler_job" "freshness" {
  name        = "${var.name_prefix}-backup-freshness-check"
  description = "Daily tick for the backup freshness Cloud Function"
  schedule    = var.freshness_check_cron
  time_zone   = "Etc/UTC"
  region      = var.region

  pubsub_target {
    topic_name = google_pubsub_topic.freshness_tick.id
    data       = base64encode("{\"check\":\"backup-freshness\"}")
  }
}

# Function source: zipped from src/functions/backup-trigger, staged in a
# small dedicated bucket (source hash in the object name → new zip = new
# object = function redeploy).
data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = var.function_source_dir
  output_path = "${path.module}/build/backup-trigger.zip"
  # Exclude compiled bytecode.
  #
  # `archive_file` zips the WHOLE source directory, and running the
  # test suite leaves __pycache__/*.pyc behind in it. Two things go
  # wrong if those are shipped:
  #
  #   1. The package hash changes every time the tests run, so
  #      `terraform plan` wants to redeploy all four functions after
  #      every local test run. The "no drift" property was only ever
  #      true until someone ran pytest.
  #   2. The deployed package carries bytecode compiled by the LOCAL
  #      Python (3.13) into a runtime that is python312. It is dead
  #      weight at best and the wrong interpreter's bytecode at worst.
  #
  # The fix is to keep build artefacts out of the deployment package.
  excludes = ["__pycache__", "*.pyc"]
}

resource "google_storage_bucket" "function_source" {
  name     = "${var.project_id}-${var.name_prefix}-fn-src"
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  labels                      = var.labels

  versioning {
    enabled = true
  }
}

resource "google_storage_bucket_object" "function_source" {
  name   = "backup-trigger-${data.archive_file.function_source.output_sha256}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function_source.output_path
}

# Dedicated runtime SA: read-only on the backup bucket, nothing else.
# Logs are captured from stdout by the Cloud Run infrastructure — no
# logging role needed.
resource "google_service_account" "freshness_fn" {
  account_id   = "${var.name_prefix}-freshness-fn-sa"
  display_name = "Backup freshness check function (read-only on backup bucket)"
}

resource "google_storage_bucket_iam_member" "fn_backup_viewer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.freshness_fn.email}"
}

# Eventarc pushes the Pub/Sub tick to the function's underlying Cloud Run
# service as this SA — it needs invoker on that one service only.
resource "google_cloudfunctions2_function" "freshness" {
  name     = "${var.name_prefix}-backup-freshness"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "check_backup_freshness"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    available_memory      = "256M"
    timeout_seconds       = 120
    max_instance_count    = 1
    min_instance_count    = 0 # scale to zero — 1 invocation/day
    service_account_email = google_service_account.freshness_fn.email

    environment_variables = {
      BACKUP_BUCKET = google_storage_bucket.backup.name
      BACKUP_PREFIX = "backups/"
      RPO_MAX_HOURS = tostring(var.rpo_max_hours)
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.freshness_tick.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.freshness_fn.email
  }
}

resource "google_cloud_run_service_iam_member" "fn_invoker" {
  location = google_cloudfunctions2_function.freshness.location
  service  = google_cloudfunctions2_function.freshness.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.freshness_fn.email}"
}

# ---------------------------------------------------------------------------
# Restore drill — Scheduler -> Pub/Sub -> Cloud Function (2nd gen).
# The freshness sentinel proves backups are RECENT; this proves they are
# USABLE: downloads the newest backup, verifies its sha256 manifest, gunzips
# and runs SQLite integrity_check + a real query (JOURNEY.md Day 9).
# Weekly by default — daily would double function invocations for little
# extra signal given checksums already gate every upload.
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "drill_tick" {
  name   = "${var.name_prefix}-restore-drill-tick"
  labels = var.labels
}

resource "google_cloud_scheduler_job" "restore_drill" {
  name        = "${var.name_prefix}-restore-drill"
  description = "Weekly automated restore drill: download, verify, integrity-check newest backup"
  schedule    = var.restore_drill_cron
  time_zone   = "Etc/UTC"
  region      = var.region

  # 05:00 UTC Sunday: after the weekend's nightly backups and STS
  # replication window (04:00), well clear of the 02:00 backup itself.
  pubsub_target {
    topic_name = google_pubsub_topic.drill_tick.id
    data       = base64encode("{\"check\":\"restore-drill\"}")
  }
}

data "archive_file" "drill_source" {
  type        = "zip"
  source_dir  = var.drill_source_dir
  output_path = "${path.module}/build/restore-drill.zip"
  # Exclude compiled bytecode.
  #
  # `archive_file` zips the WHOLE source directory, and running the
  # test suite leaves __pycache__/*.pyc behind in it. Two things go
  # wrong if those are shipped:
  #
  #   1. The package hash changes every time the tests run, so
  #      `terraform plan` wants to redeploy all four functions after
  #      every local test run. The "no drift" property was only ever
  #      true until someone ran pytest.
  #   2. The deployed package carries bytecode compiled by the LOCAL
  #      Python (3.13) into a runtime that is python312. It is dead
  #      weight at best and the wrong interpreter's bytecode at worst.
  #
  # The fix is to keep build artefacts out of the deployment package.
  excludes = ["__pycache__", "*.pyc"]
}

resource "google_storage_bucket_object" "drill_source" {
  name   = "restore-drill-${data.archive_file.drill_source.output_sha256}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.drill_source.output_path
}

# Dedicated runtime SA, same least-privilege shape as the freshness fn:
# read-only on the backup bucket, nothing else.
resource "google_service_account" "drill_fn" {
  account_id   = "${var.name_prefix}-drill-fn-sa"
  display_name = "Automated restore drill (read-only on backup bucket)"
}

resource "google_storage_bucket_iam_member" "drill_backup_viewer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.drill_fn.email}"
}

resource "google_cloudfunctions2_function" "restore_drill" {
  name     = "${var.name_prefix}-restore-drill"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "run_restore_drill"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.drill_source.name
      }
    }
  }

  service_config {
    # Downloading, gunzipping and integrity-checking a multi-MB backup needs
    # more headroom than the freshness check.
    available_memory      = "512M"
    timeout_seconds       = 300
    max_instance_count    = 1
    min_instance_count    = 0
    service_account_email = google_service_account.drill_fn.email

    environment_variables = {
      BACKUP_BUCKET = google_storage_bucket.backup.name
      BACKUP_PREFIX = "backups/"
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.drill_tick.id

    # RETRY on failure. A transient GCS 503 during the weekly drill
    # would otherwise become a permanent weekly failure until the next
    # run — with DO_NOT_RETRY, one blip means the week's drill is lost
    # and nobody is paged. Retrying is the right behaviour for a check
    # that is supposed to prove the backup is restorable.
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.drill_fn.email
  }

  depends_on = [google_storage_bucket_iam_member.drill_backup_viewer]
}

resource "google_cloud_run_service_iam_member" "drill_invoker" {
  location = google_cloudfunctions2_function.restore_drill.location
  service  = google_cloudfunctions2_function.restore_drill.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.drill_fn.email}"
}

# ---------------------------------------------------------------------------
# Key version retirement — stops the silent KMS cost leak.
#
# Rotating a key every 90 days adds a billed key version every 90 days
# and nothing ever removes the old one (measured — see the note at the
# top of this file). This function sweeps the two keyrings monthly and
# destroys versions that are no longer primary and are older than the
# backup retention window.
#
# The retention window is a hard floor: destroying a key version makes
# the data it encrypted unreadable, so a version is only retired once no
# restorable backup could still need it.
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "retire_tick" {
  name   = "${var.name_prefix}-key-retire-tick"
  labels = var.labels
}

resource "google_cloud_scheduler_job" "key_retirement" {
  name        = "${var.name_prefix}-key-version-retirement"
  description = "Monthly sweep: destroy superseded CMEK key versions that no restorable backup needs"
  schedule    = var.key_retirement_cron
  time_zone   = "Etc/UTC"
  region      = var.region

  pubsub_target {
    topic_name = google_pubsub_topic.retire_tick.id
    data       = base64encode("{\"check\":\"key-version-retirement\"}")
  }
}

data "archive_file" "retirement_source" {
  type        = "zip"
  source_dir  = var.retirement_source_dir
  output_path = "${path.module}/build/key-version-retirement.zip"
  # Exclude compiled bytecode.
  #
  # `archive_file` zips the WHOLE source directory, and running the
  # test suite leaves __pycache__/*.pyc behind in it. Two things go
  # wrong if those are shipped:
  #
  #   1. The package hash changes every time the tests run, so
  #      `terraform plan` wants to redeploy all four functions after
  #      every local test run. The "no drift" property was only ever
  #      true until someone ran pytest.
  #   2. The deployed package carries bytecode compiled by the LOCAL
  #      Python (3.13) into a runtime that is python312. It is dead
  #      weight at best and the wrong interpreter's bytecode at worst.
  #
  # The fix is to keep build artefacts out of the deployment package.
  excludes = ["__pycache__", "*.pyc"]
}

resource "google_storage_bucket_object" "retirement_source" {
  name   = "key-version-retirement-${data.archive_file.retirement_source.output_sha256}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.retirement_source.output_path
}

# Dedicated SA. It needs to list key versions and destroy them — and
# nothing else. It is a separate principal from the other functions so
# that the ability to destroy key material is not shared with them.
resource "google_service_account" "retirement_fn" {
  account_id   = "${var.name_prefix}-key-retire-fn-sa"
  display_name = "CMEK key version retirement (scheduled sweep)"
}

resource "google_kms_key_ring_iam_member" "retirement_primary" {
  key_ring_id = google_kms_key_ring.primary.id
  role        = "roles/cloudkms.admin"
  member      = "serviceAccount:${google_service_account.retirement_fn.email}"
}

resource "google_kms_key_ring_iam_member" "retirement_dr" {
  key_ring_id = google_kms_key_ring.dr.id
  role        = "roles/cloudkms.admin"
  member      = "serviceAccount:${google_service_account.retirement_fn.email}"
}

resource "google_cloudfunctions2_function" "key_retirement" {
  name     = "${var.name_prefix}-key-version-retirement"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "run_key_version_retirement"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.retirement_source.name
      }
    }
  }

  service_config {
    available_memory      = "256M"
    timeout_seconds       = 300
    max_instance_count    = 1
    min_instance_count    = 0
    service_account_email = google_service_account.retirement_fn.email

    environment_variables = {
      PROJECT_ID = var.project_id
      # The retention window is the floor: a version younger than this
      # could still be needed to decrypt a live backup.
      RETENTION_DAYS = tostring(var.backup_retention_days)
      # The keyrings to sweep, as fully-qualified keyring resource names.
      KEYRINGS = join(",", [
        "projects/${var.project_id}/locations/${var.region}/keyRings/${google_kms_key_ring.primary.name}",
        "projects/${var.project_id}/locations/${var.dr_region}/keyRings/${google_kms_key_ring.dr.name}",
      ])
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.retire_tick.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.retirement_fn.email
  }

  depends_on = [
    google_kms_key_ring_iam_member.retirement_primary,
    google_kms_key_ring_iam_member.retirement_dr,
  ]
}

resource "google_cloud_run_service_iam_member" "retirement_invoker" {
  location = google_cloudfunctions2_function.key_retirement.location
  service  = google_cloudfunctions2_function.key_retirement.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.retirement_fn.email}"
}

# ---------------------------------------------------------------------------
# Alerting — log-based metric on RPO_BREACH + email notification
# ---------------------------------------------------------------------------

resource "google_logging_metric" "rpo_breach" {
  name        = "${var.name_prefix}-rpo-breach"
  description = "Counts RPO_BREACH errors emitted by the backup freshness function"
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${google_cloudfunctions2_function.freshness.name}"
    severity>=ERROR
    jsonPayload.message:"RPO_BREACH"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "DR alerts (${var.alert_email})"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_alert_policy" "rpo_breach" {
  display_name = "RPO breach — backup older than ${var.rpo_max_hours}h"
  combiner     = "OR"

  conditions {
    display_name = "RPO_BREACH log entries > 0"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.rpo_breach.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content = <<-EOT
      The newest backup in gs://${google_storage_bucket.backup.name} is older
      than ${var.rpo_max_hours}h (or no backup exists). Check:
      1. Is the primary VM running? (cron fires at 02:00 UTC on the VM)
      2. /var/log/dr-backup.log on the VM for backup.sh failures
      3. Cloud Function logs for the freshness check itself
      Runbook: docs/05-troubleshooting.md in the gcp-hybrid-dr repo.
    EOT
  }
}

# ---------------------------------------------------------------------------
# Restore-drill alerting — same pattern as RPO breach: structured ERROR log
# ("RESTORE_DRILL_FAIL") -> log-based metric -> email alert.
# ---------------------------------------------------------------------------

resource "google_logging_metric" "restore_drill_fail" {
  name        = "${var.name_prefix}-restore-drill-fail"
  description = "Counts failed automated restore drills (checksum, gzip, integrity or query failure)"
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${google_cloudfunctions2_function.restore_drill.name}"
    severity>=ERROR
    jsonPayload.message:"RESTORE_DRILL_FAIL"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "restore_drill_fail" {
  display_name = "Restore drill FAILED — newest backup not restorable"
  combiner     = "OR"

  conditions {
    display_name = "RESTORE_DRILL_FAIL log entries > 0"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.restore_drill_fail.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content = <<-EOT
      The weekly automated restore drill failed against
      gs://${google_storage_bucket.backup.name}. The backup may be corrupt,
      its manifest wrong, or the schema changed. A backup that cannot be
      restored does not exist for DR purposes — treat this as a P1:
      1. Read the restore-drill function logs for the exact failure step
      2. Run src/scripts/verify-backup.sh manually from an admin machine
      3. Check the primary VM's /var/log/dr-backup.log around the last runs
      Runbook: docs/05-troubleshooting.md in the gcp-hybrid-dr repo.
    EOT
  }
}
