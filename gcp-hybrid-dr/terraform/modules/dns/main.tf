# ---------------------------------------------------------------------------
# DNS module: Cloud DNS zone + alert-driven failover automation.
#
# OPTIONAL (count in root, enable_dns = false by default): a real domain
# costs money at a registrar. The zone is $0.25/mo when enabled.
#
# DESIGN (JOURNEY.md Day 10 — replaces the Day 9 A-record version):
#
# The public record is a CNAME, and the two failover targets are
# HOSTNAMES rather than IP addresses:
#
#   app.dr-demo.example.com.  CNAME -> primary.dr-demo.example.com.
#                                        A  -> 34.x.x.x  (the on-prem VM)
#                                     or
#                                   -> <service>.a.run.app  (the standby)
#
# Why CNAME instead of rewriting A records:
#   1. The target is a NAME, so it never goes stale. Google's Cloud Run
#      front-end IPs rotate; an A record pinned to last month's IPs is a
#      broken record. A CNAME to *.a.run.app always resolves live.
#   2. The record TYPE never changes, so there is no A<->CNAME conflict
#      and no window where the name has no usable record. Failover is
#      ONE atomic DNS change.
#
# It also means failover works WITHOUT buying a domain: a Cloud DNS zone
# is authoritative for its own name, and its nameservers answer queries
# from anyone who asks them directly:
#
#   dig @ns-cloud-a1.googledomains.com app.dr-demo.example.com
#
# Registration is only needed for real-world public resolution.
#
# Prerequisite for an automatic flip TO the standby: the Cloud Run
# service must exist so its *.a.run.app hostname is known. Without it the
# function logs FAILOVER_TARGET_MISSING loudly instead of failing
# silently.
# ---------------------------------------------------------------------------

resource "google_dns_managed_zone" "dr" {
  name        = var.zone_name
  dns_name    = var.dns_name
  description = "DR failover zone (portfolio project)"

  dnssec_config {
    state = "on"
  }
}

# ---------------------------------------------------------------------------
# The two failover targets, as names.
#
# primary_target: a hostname whose A record points at the VM's static IP.
#                 Terraform owns that A record, so the failover function
#                 never has to touch IP literals.
# dr_target:      the Cloud Run standby's *.a.run.app hostname. Stable by
#                 construction — Google resolves it to the live front end.
#
# NOTE ON THE ZONE APEX: a CNAME may not exist at a zone's apex (RFC 1912
# §2.3.2 — a CNAME cannot coexist with any other record type at the same
# name, and the apex always carries the zone's SOA/NS). The public record
# therefore lives ONE LEVEL BELOW the apex, e.g. for a zone
# "dr-demo.example.com." the public name is "www.dr-demo.example.com.".
# That is also how real deployments do it (the apex serves the SOA/NS).
# ---------------------------------------------------------------------------

resource "google_dns_record_set" "primary_a" {
  managed_zone = google_dns_managed_zone.dr.name
  name         = var.primary_target_name
  type         = "A"
  ttl          = var.record_ttl
  rrdatas      = [var.primary_ip]
}

# THE public record. Its rrdatas are what the failover function rewrites:
# it points at primary_target_name while healthy, and at the DR standby
# while an incident is open.
resource "google_dns_record_set" "active" {
  managed_zone = google_dns_managed_zone.dr.name
  name         = var.public_record_name
  type         = "CNAME"
  ttl          = var.record_ttl

  # Worst-case stale-traffic window during failover is one TTL: 300s keeps
  # that at ~5 min without burning extra queries (TTL <60s bills more on
  # some resolvers and gains little behind a 5-min detection window).
  rrdatas = [var.primary_target_name]
}

# ---------------------------------------------------------------------------
# Failover event path: dedicated topic <- Pub/Sub notification channel bound
# to the primary_down alert policy (binding happens in root monitoring.tf).
# One topic per purpose means this function never needs to parse WHICH alert
# fired — anything arriving here IS a primary-down incident open/close.
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "failover_events" {
  name   = "${var.name_prefix}-dns-failover-events"
  labels = var.labels
}

resource "google_monitoring_notification_channel" "failover_pubsub" {
  display_name = "DNS failover events (${google_pubsub_topic.failover_events.name})"
  type         = "pubsub"
  labels = {
    # The Pub/Sub channel type's label key is "topic" (NOT "topic_id").
    # The API rejects anything else with
    # "labels must conform to the channel type's descriptor".
    topic = google_pubsub_topic.failover_events.id
  }
}

# ---------------------------------------------------------------------------
# The Monitoring NOTIFICATION service account needs publisher rights on the
# topic, or every notification fails with:
#
#   "An error occurred while publishing notification to Cloud Pub/Sub topic
#    ... Possible causes: 1) you don't have the required role; or
#    2) Cloud Pub/Sub API is not enabled ... PERMISSION_DENIED"
#
# The account to grant it to is NOT the ordinary monitoring service agent
# (service-PROJECT_NUMBER@gcp-sa-monitoring.iam.gserviceaccount.com) but
# the separate NOTIFICATION agent:
#
#   service-PROJECT_NUMBER@gcp-sa-monitoring-notification.iam.gserviceaccount.com
#
# Cloud Monitoring creates that account the first time a Pub/Sub channel
# is added to a project. The notification agent is what actually
# publishes the alert payload.
# ---------------------------------------------------------------------------

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_pubsub_topic_iam_member" "monitoring_notification_publisher" {
  topic  = google_pubsub_topic.failover_events.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# Failover function — zipped from src/functions/dns-failover, staged in a
# small dedicated source bucket (hash-named object -> new zip = redeploy).
# ---------------------------------------------------------------------------

data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = var.function_source_dir
  output_path = "${path.module}/build/dns-failover.zip"
}

resource "google_storage_bucket" "function_source" {
  name     = "${var.project_id}-${var.name_prefix}-fn-src-dns"
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
  name   = "dns-failover-${data.archive_file.function_source.output_sha256}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function_source.output_path
}

resource "google_service_account" "dns_failover_fn" {
  account_id   = "${var.name_prefix}-dns-failover-sa"
  display_name = "DNS failover function (edit record sets only)"
}

# ---------------------------------------------------------------------------
# Least-privilege IAM for the failover function.
#
# WHY A CUSTOM ROLE INSTEAD OF A PREDEFINED ONE:
#
# 1. `roles/dns.resourceRecordsAdmin` — the role the original design used —
#    DOES NOT EXIST on GCP. The IAM API returns 404 for it, and the
#    Cloud DNS setIamPolicy call accepts the binding and then SILENTLY
#    DROPS it. The result is a function that looks correctly permissioned
#    and can do nothing at all.
#
# 2. Zone-level IAM (`google_dns_managed_zone_iam_member`) does not work
#    on this account: the dns/v2 endpoint returns HTTP 500
#    "Internal error encountered" for managedZone.setIamPolicy on every
#    zone, and dns/v1 accepts the call but stores an empty policy. The
#    provider and the gcloud CLI both use dns/v2 by default, so the
#    original design was blocked on a platform limitation rather than a
#    design choice.
#
# 3. `roles/dns.admin` DOES work at the project level, but it also grants
#    zone create/delete and IAM policy mutation — a far larger blast
#    radius than a failover function needs.
#
# So: a PROJECT-LEVEL CUSTOM ROLE with exactly the permissions the
# function needs. It cannot create or delete zones, cannot touch IAM
# policies, and cannot affect any other project. It CAN read and modify
# resource record sets and submit changes — which is the entire job.
#
# The role is created once by the operator (see the README "Quick Start");
# Terraform only manages the BINDING, so the role definition is not
# destroyed and recreated on every apply.
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "dns_failover_record_editor" {
  # The binding is only created when a role id was supplied. Without the
  # guard, an empty `role` would reach the IAM API and fail the apply
  # with an opaque error — and the variable's own documentation says
  # "leave empty to skip the binding".
  count = var.dns_failover_role_id == "" ? 0 : 1

  project = var.project_id
  role    = var.dns_failover_role_id
  member  = "serviceAccount:${google_service_account.dns_failover_fn.email}"
}

resource "google_cloudfunctions2_function" "dns_failover" {
  name     = "${var.name_prefix}-dns-failover"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "handle_monitor_alert"
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
    min_instance_count    = 0 # scale to zero — invoked only on incident edges
    service_account_email = google_service_account.dns_failover_fn.email

    environment_variables = {
      PROJECT_ID   = var.project_id
      MANAGED_ZONE = google_dns_managed_zone.dr.name
      RECORD_NAME  = google_dns_record_set.active.name
      RECORD_TYPE  = google_dns_record_set.active.type
      RECORD_TTL   = tostring(var.record_ttl)

      # Failover targets are NAMES, not IPs.
      PRIMARY_TARGET = google_dns_record_set.primary_a.name
      DR_TARGETS     = var.dr_target

      # The standby is probed before the record is moved. Failing over into
      # an unreachable standby is worse than staying on a degraded primary.
      DR_HEALTH_URL = var.dr_health_url
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.failover_events.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.dns_failover_fn.email
  }

  depends_on = [google_project_iam_member.dns_failover_record_editor]
}

resource "google_cloud_run_service_iam_member" "fn_invoker" {
  location = google_cloudfunctions2_function.dns_failover.location
  service  = google_cloudfunctions2_function.dns_failover.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.dns_failover_fn.email}"
}
