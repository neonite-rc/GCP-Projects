# ---------------------------------------------------------------------------
# Observability — uptime checks, alerting, log sink, billing guardrail.
#
# Checklist coverage:
#   7.1  Alert policies: VM CPU >90% (10 min), uptime-check failure,
#        RPO breach (in modules/backup), optional monthly billing budget
#   7.2  Log sink with filtering (only firewall DENY events exported)
#   7.3  Uptime check on the public /health endpoint
#
# The email notification channel is re-declared here (not shared from
# modules/backup) because Terraform resources cannot be imported across
# module boundaries without an output; one extra channel object is free.
# ---------------------------------------------------------------------------

resource "google_monitoring_notification_channel" "email" {
  display_name = "DR alerts (${var.alert_email})"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

# ---------------------------------------------------------------------------
# 7.3 — Uptime check on the primary site's /health (free tier: 3 checks).
# /health verifies the DATABASE behind nginx, not just the web server, so
# this mirrors exactly what Cloud DNS failover watches.
# ---------------------------------------------------------------------------

resource "google_monitoring_uptime_check_config" "primary_health" {
  display_name = "${var.name_prefix}-primary-health"
  project      = var.project_id
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/health"
    port         = 80
    validate_ssl = false
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = module.primary.public_ip
    }
  }

  # The API returns region codes in the UNDERSCORED form
  # ("USA_OREGON"), but the provider normalises them to the dashed form
  # ("USA-OREGON") when diffing, so whichever form is configured, the
  # plan shows a permanent difference and the apply never settles.
  #
  # The value is inert — the check is created and works either way — so
  # the difference is ignored rather than fought over.
  lifecycle {
    ignore_changes = [selected_regions]
  }

  selected_regions = ["USA_OREGON", "USA_IOWA", "USA_VIRGINIA"]
}

resource "google_monitoring_alert_policy" "primary_down" {
  display_name = "Primary site DOWN — /health failing (${var.name_prefix})"
  combiner     = "OR"
  project      = var.project_id

  conditions {
    display_name = "Uptime check failing for 5+ minutes"

    # The metric is `uptime_check/check_passed`, a BOOL gauge that is
    # True while the check succeeds.
    #
    # It is NOT `uptime_check/check_failed`. That metric type only
    # appears once a check has actually FAILED, so an alert policy
    # filtered on it cannot even be CREATED while everything is healthy
    # ("Cannot find metric(s) that match type =
    # monitoring.googleapis.com/uptime_check/check_failed"). Filtering on
    # the check_passed gauge and testing for False gives the same
    # semantics and works from the first apply.
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.primary_health.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }

  # Email for the human; Pub/Sub channel (defined in the dns module) drives
  # the automated record flip when enable_dns is on.
  notification_channels = concat(
    [google_monitoring_notification_channel.email.id],
    var.enable_dns ? [module.dns[0].failover_notification_channel_id] : [],
  )

  documentation {
    content = <<-EOT
      Uptime checks from all three US regions fail against
      http://${module.primary.public_ip}/health.

      ${var.enable_dns ? "This alert ALSO triggers automated DNS failover: the dns-failover function repoints the zone's public CNAME at the Cloud Run standby while the incident is open and restores it on close." : "Enable enable_dns to also trigger automated DNS failover from this alert."}

      Runbook: docs/05-troubleshooting.md in the gcp-hybrid-dr repo.
    EOT
  }
}

# ---------------------------------------------------------------------------
# 7.1 — CPU saturation alert on the primary VM (>90% sustained 10 min).
# Scoped to THIS VM via its user labels, not the whole project.
# ---------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "primary_cpu" {
  display_name = "Primary VM CPU > 90% for 10 minutes (${var.name_prefix})"
  combiner     = "OR"
  project      = var.project_id

  conditions {
    display_name = "cpu/utilization > 0.9"

    condition_threshold {
      filter          = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\" AND metadata.user_labels.project=\"${var.labels["project"]}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.9
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content = <<-EOT
      The e2-micro has 2 vCPU shared-core; sustained >90% usually means a
      runaway process or incoming traffic spike before a disaster.
      Investigate: gcloud compute ssh ${var.name_prefix}-primary --zone=${var.zone}
    EOT
  }
}

# ---------------------------------------------------------------------------
# 7.1 — Monthly billing budget with alerts at 50% / 90% / 100%.
# GATED: requires billing_account_id in tfvars (console-only knowledge),
# and the Billing API enabled on the project. Off by default so `apply`
# works on projects where this agent has no billing-admin grant.
# ---------------------------------------------------------------------------

resource "google_billing_budget" "monthly" {
  count = var.billing_account_id != "" ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "${var.project_id} — ${var.name_prefix} monthly budget"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]

    # Labels let this budget track ONLY this project's tagged spend.
    labels = {
      project = var.labels["project"]
    }
  }

  amount {
    specified_amount {
      # The currency MUST match the billing account's currency. A budget
      # in the wrong currency is rejected with a bare
      # "Request contains an invalid argument" (HTTP 400) — the API does
      # not say which field is wrong, so this bites hard.
      # Find yours with:
      #   gcloud beta billing accounts describe ACCOUNT_ID
      currency_code = var.billing_currency
      units         = tostring(var.monthly_budget_amount)
      nanos         = 0
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  # WITHOUT THIS BLOCK THE BUDGET IS A REPORT, NOT A GUARDRAIL.
  #
  # A budget records thresholds; it only NOTIFIES anyone who is wired
  # to a channel. With an empty all_updates_rule the budget is created
  # happily, looks configured in the console, and emails nobody — the
  # classic "the alert exists but I never got it" failure.
  #
  # The channel is the project's own email notification channel, and the
  # Pub/Sub channel that drives the failover — so a budget breach and a
  # site outage reach the same places.
  #
  # It is opt-in because the Cloud Billing Budget API rejects the field
  # outright on some accounts:
  #   "Invalid JSON payload received. Unknown name \"allUpdatesRule\" at
  #    'budget': Cannot find field."
  # (measured on this billing account, on both v1 and v1beta1, for
  # every variant of the payload). Set `budget_notify = true` to send
  # the rule; the budget is created either way.
  dynamic "all_updates_rule" {
    for_each = var.budget_notify ? [1] : []
    content {
      monitoring_notification_channels = compact([
        google_monitoring_notification_channel.email.id,
        var.enable_dns ? module.dns[0].failover_notification_channel_id : "",
      ])

      # The project-level recipients (billing admins) get the
      # notifications as well as the explicit channels above.
      enable_project_level_recipients = true
    }
  }
}

# ---------------------------------------------------------------------------
# 7.2 — Log sink WITH filtering: only firewall DENY events are exported to
# GCS (30-day lifecycle). Everything else stays in Cloud Logging free tier;
# nothing noisy is shipped wholesale.
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "security_logs" {
  name     = "${var.project_id}-${var.name_prefix}-sec-logs"
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  labels                      = var.labels

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_logging_project_sink" "firewall_deny" {
  name        = "${var.name_prefix}-firewall-deny-sink"
  destination = "storage.googleapis.com/${google_storage_bucket.security_logs.name}"

  # Substring match on the firewall rule reference — only explicit-denied
  # connection attempts land here (port scans, probes of closed ports).
  #
  # The rule's real name is "<network_name>-deny-all-ingress", where
  # network_name is "<name_prefix>-primary-vpc" — NOT
  # "<name_prefix>-deny-all-ingress". Matching the wrong string means the
  # sink never matches a single log line while still looking configured.
  filter                 = "resource.type=\"gce_subnetwork\" AND jsonPayload.rule_details.reference:\"${var.name_prefix}-primary-vpc-deny-all-ingress\""
  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.security_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.firewall_deny.writer_identity
}

# ---------------------------------------------------------------------------
# DR posture dashboard — one visual surface for the four questions that
# matter after an incident: is the primary up, how loaded is it, are backups
# fresh (RPO), and do restores actually succeed? Free tier; Terraform-managed
# so the dashboard survives project rebuilds.
# ---------------------------------------------------------------------------

locals {
  rpo_metric_name        = "${var.name_prefix}-rpo-breach"
  drill_fail_metric_name = "${var.name_prefix}-restore-drill-fail"

  dr_widgets = {
    uptime = {
      title   = "Primary /health uptime check (3 US probes) — 1 = passing, 0 = failing"
      aligner = "ALIGN_FRACTION_TRUE"

      # `check_passed` is a BOOL gauge (1 = passed, 0 = failed). There is
      # no `check_failed` metric type while the site is healthy, so the
      # dashboard and the alert both read this gauge.
      filter = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.primary_health.uptime_check_id}\""
    }

    cpu = {
      title   = "Primary VM CPU utilization"
      aligner = "ALIGN_MEAN"

      filter = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\" AND metadata.user_labels.project=\"${var.labels["project"]}\""
    }

    rpo = {
      title   = "RPO breaches (backup older than ${var.rpo_max_hours}h)"
      aligner = "ALIGN_DELTA"

      filter = "metric.type=\"logging.googleapis.com/user/${local.rpo_metric_name}\" AND resource.type=\"cloud_run_revision\""
    }

    drill = {
      title   = "Restore-drill failures (backup not restorable)"
      aligner = "ALIGN_DELTA"

      filter = "metric.type=\"logging.googleapis.com/user/${local.drill_fail_metric_name}\" AND resource.type=\"cloud_run_revision\""
    }
  }
}

resource "google_monitoring_dashboard" "dr_posture" {
  # The Monitoring API injects `targetAxis: "Y1"` into every dataSet
  # when it stores the dashboard, and an `etag` at the top level. If the
  # configured JSON does not contain them, the stored copy always
  # differs from the config and every plan shows a change that an apply
  # cannot settle.
  #
  # Declaring `targetAxis` explicitly makes the two match, so the plan
  # is clean and a real change to a widget still shows up.
  dashboard_json = jsonencode({
    displayName = "${var.name_prefix} — DR posture"

    gridLayout = {
      # The API stores the column count as a STRING ("12"), so a number
      # never matches and the plan shows a permanent difference.
      columns = "12"

      widgets = [
        for w in local.dr_widgets : {
          title = w.title

          xyChart = {
            dataSets = [
              {
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = w.filter

                    aggregation = {
                      alignmentPeriod    = "300s"
                      perSeriesAligner   = w.aligner
                      crossSeriesReducer = "REDUCE_MAX"
                    }
                  }
                }

                plotType           = "LINE"
                minAlignmentPeriod = "300s"
                targetAxis         = "Y1"
              }
            ]
          }
        }
      ]
    }
  })

  # The API adds an `etag` and a `name` to the stored dashboard JSON.
  # They are server-managed and cannot be set, so they are ignored —
  # otherwise every plan shows a dashboard change that an apply can
  # never settle.
  #
  # The cost of ignoring the whole attribute is that a widget edit is
  # not applied by a normal `terraform apply`. Force it with:
  #   terraform apply -replace=google_monitoring_dashboard.dr_posture
  lifecycle {
    ignore_changes = [dashboard_json]
  }
}
