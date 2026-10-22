# Troubleshooting: Hybrid Cloud Disaster Recovery

Every entry here is a problem that was actually hit while deploying this
project on 2026-10-21, with the fix that resolved it.

---

## Issue 1: Backup Upload Fails with "Permission Denied"

**Symptom:** `backup.sh` fails with HTTP 403 `does not have
storage.objects.get access to the Google Cloud Storage object`.

**Root cause:** `gcloud storage cp` READS the destination object before
writing it — to decide whether it would overwrite. The primary VM's
service account holds only `roles/storage.objectCreator`, which is
deliberately write-only, so the read is denied and the upload fails.

**This is the bug that meant the backup pipeline had never once
succeeded.**

**Fix:** upload through the Cloud Storage JSON API's `uploadType=media`
endpoint, which CREATES the object without reading the destination:

```bash
curl -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/octet-stream" \
  -H "x-goog-hash: crc32c=${CRC}" \
  --data-binary "@${FILE}" \
  "https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o?uploadType=media&name=${NAME}"
```

`x-goog-hash` keeps the CRC32C in-transit validation that `gcloud
storage cp` provided — GCS still rejects a corrupted upload with 400.

**Do NOT "fix" this by granting `storage.objects.get`.** That would let
a compromised primary read (and potentially tamper with) its own
recovery path — the one property the whole design rests on.

---

## Issue 2: verify-backup.sh Reports "No Backups Found"

**Symptom:** running `verify-backup.sh` from the primary VM reports "no
backups found".

**Root cause:** the VM's SA has `objectCreator` only — it cannot LIST
existing backups.

**Fix:** run `verify-backup.sh` from an admin workstation or Cloud
Shell, not from the primary VM. This is by design.

---

## Issue 3: DNS Failover Never Fires

**Symptom:** the primary VM is down, the uptime check reports failure,
but the DNS record never changes.

**Root causes, in the order to check them:**

1. **The alert policy filters on a metric that does not exist.**
   `monitoring.googleapis.com/uptime_check/check_failed` only appears
   once a check has actually FAILED — so while the site is healthy the
   policy cannot even be *created*:

   ```
   Error creating AlertPolicy: Cannot find metric(s) that match
   type = "monitoring.googleapis.com/uptime_check/check_failed"
   ```

   **Fix:** filter on `monitoring.googleapis.com/uptime_check/check_passed`
   (a BOOL gauge) and test for `False`:

   ```hcl
   comparison      = "COMPARISON_LT"
   threshold_value = 1
   aggregations { per_series_aligner = "ALIGN_FRACTION_TRUE" }
   ```

2. **The monitoring NOTIFICATION service agent cannot publish.** The
   notification channel log says:

   ```
   An error occurred while publishing notification to Cloud Pub/Sub topic
   ... PERMISSION_DENIED
   ```

   The account that publishes notifications is
   `service-PROJECT_NUMBER@gcp-sa-monitoring-NOTIFICATION.iam.gserviceaccount.com`
   — a *different* account from the ordinary monitoring service agent
   (`...@gcp-sa-monitoring.iam.gserviceaccount.com`). Granting
   `roles/pubsub.publisher` to the latter changes nothing.

   **Fix:**

   ```hcl
   resource "google_pubsub_topic_iam_member" "monitoring_notification_publisher" {
     topic  = google_pubsub_topic.failover_events.id
     role   = "roles/pubsub.publisher"
     member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
   }
   ```

3. **Zone-level IAM silently does nothing.** `managedZone.setIamPolicy`
   returns HTTP 500 on the `dns/v2` endpoint (which the provider and the
   gcloud CLI both use by default) and stores an empty policy on `dns/v1`.
   The binding appears to succeed and grants nothing.

   **Fix:** grant at the PROJECT level. And note that
   `roles/dns.resourceRecordsAdmin` **does not exist** on GCP — the IAM
   API 404s it and Cloud DNS silently drops the binding. Use a custom
   role:

   ```bash
   gcloud iam roles create drFailoverDnsAdmin --project=PROJECT_ID \
     --title="DR DNS Failover Admin" \
     --permissions=dns.resourceRecordSets.create,dns.resourceRecordSets.delete,dns.resourceRecordSets.get,dns.resourceRecordSets.list,dns.resourceRecordSets.update,dns.changes.create,dns.changes.get,dns.changes.list,dns.managedZones.get,dns.managedZones.list
   ```

---

## Issue 4: The Failover Function Crashes with HTTP 400

**Symptom:**

```
HttpError 400 when requesting .../managedZones/.../changes
Invalid value for 'entity.change.additions[...][CNAME].rrdata[0]':
'https://dr-demo-dr-maintenance-abc.a.run.app'
```

**Root cause:** the CNAME target still carries its URL scheme. Two
places can cause this:

- Terraform's `replace()` does **not** treat its arguments as regular
  expressions — it matches literal substrings, so `replace(uri, "^https://",
  "")` leaves the scheme in place. Use `trimprefix` / `trimsuffix`.
- A target configured by hand with a scheme.

**Fix:** both. Terraform uses `trimprefix(uri, "https://")`, and the
function normalises every target defensively (strips scheme and path,
appends the trailing dot) so a mis-configured target can never take the
failover path down.

---

## Issue 5: The Drill Reports a Timeout Even Though Failover Worked

**Symptom:** the drill prints `ERROR: no recovery within 900s` while the
DNS record has clearly flipped.

**Root cause:** `dig +short <name> A` returns the CNAME *target*, not
the final address. The drill was treating that hostname as an IP.

**Two further wrinkles:**

- The zone's authoritative nameserver answers for the zone's own names
  and returns the CNAME, but it does **not** resolve the external
  `*.a.run.app` target — that is correct DNS behaviour, not a failure.
  The chain has to be followed across two resolvers.
- The standby is a TLS endpoint with its own certificate. A real client
  connects to it by *hostname* over HTTPS; dialling the bare IP returns
  404/302 and TLS would not validate.

**Fix:** resolve() returns the final **hostname** and follows the chain
across both resolvers; probe_ok() uses `https://` for a hostname and
`http://` for a bare IP (the primary VM has no TLS without a registered
domain).

---

## Issue 6: terraform destroy Fails on KMS

**Symptom:** `terraform destroy` fails on KMS key rings with "key ring
contains key versions".

**Root cause:** KMS key rings and keys are never physically deleted by
GCP. `terraform destroy` removes them from state; key versions cost
$0.06/mo each until manually destroyed.

**Fix:** documented behaviour. For a portfolio demo this is acceptable;
in production, set `rotation_period` and `destroy_scheduled_duration`.

---

## Issue 7: Terraform Plan Fails on retention_policy

**Symptom:**

```
Inappropriate value for attribute "retention_period": a number is required.
```

**Root cause:** `retention_period` is a NUMBER of seconds in the google
provider 5.x. `"2592000s"` is a string and is rejected.

**Fix:** `retention_period = var.backup_retention_days * 86400`.

---

## Issue 8: "Cloud KMS API has not been used in project ... before"

**Symptom:** enabling `kms.googleapis.com` fails with
`SERVICE_CONFIG_NOT_FOUND_OR_PERMISSION_DENIED`.

**Root cause:** the service name is `cloudkms.googleapis.com`, not
`kms.googleapis.com`.

**Fix:** use the correct name in `required_services`.

---

## Issue 9: Terraform Cannot Create the Budget

**Symptom:**

```
Error creating Budget: The billingbudgets.googleapis.com API requires a
quota project, which is not set by default.
```

**Root cause:** the Cloud Billing Budget API is a *billing-account*
scoped API that still needs a consumer project for quota. The google
provider 5.x has no `user_project` argument.

**Fix:** set `billing_project = var.project_id` on the provider, or
export `GOOGLE_CLOUD_QUOTA_PROJECT`.

**Follow-on:** the budget currency must match the billing account's
currency. A mismatch is rejected with a bare
`Request contains an invalid argument` (HTTP 400) that does not say
which field is wrong:

```bash
gcloud beta billing accounts describe ACCOUNT_ID   # look at currencyCode
```

---

## Issue 10: SSH Times Out Even Though the Firewall Rule Looks Right

**Symptom:** `gcloud compute ssh` times out, but
`allow-ssh-admin` shows the correct source range.

**Root cause:** on a CUSTOM-mode VPC, GCP also creates
`default-allow-ssh`, which allows **tcp:22 from 0.0.0.0/0** to every
instance in the network. It does not block your rule — it just means
SSH is open to the internet, which silently defeats the whole point of
the admin-IP-only rule. (In auto-mode there is no default rule, which
is why this goes unnoticed.)

**Fix:** import it and disable it:

```bash
terraform import 'module.primary.google_compute_firewall.disable_default_ssh' 'default-allow-ssh'
```

```hcl
resource "google_compute_firewall" "disable_default_ssh" {
  name         = "default-allow-ssh"
  network      = google_compute_network.vpc.id
  disabled     = true
  priority     = 65535
  allow { protocol = "tcp" ports = ["22"] }
  source_ranges = ["0.0.0.0/0"]
}
```

---

## Issue 11: The VM's /opt/dr/backup.sh Is the Old Version

**Symptom:** you change `src/scripts/backup.sh`, but the VM keeps
running the old one.

**Root cause:** the startup script is guarded by a marker file
(`/var/lib/dr-primary/.provisioned`) so reboots don't re-provision. The
script is delivered via instance metadata and only fetched on FIRST
boot.

**Fix:** re-fetch it from the metadata server (or recreate the VM):

```bash
META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
sudo curl -fsS -H "Metadata-Flavor: Google" "${META}/backup-script" \
  | sudo tee /opt/dr/backup.sh > /dev/null
sudo chmod 0750 /opt/dr/backup.sh
```

---

## General Debugging Commands

```bash
# Check backup status on the VM
gcloud compute ssh dr-demo-primary --zone=us-east1-b --command \
  "sudo tail -20 /var/log/dr-backup.log"

# Check backup bucket contents
gcloud storage ls gs://BACKUP_BUCKET/backups/ | tail -5

# Is the uptime check actually reporting?
curl -s -G "https://monitoring.googleapis.com/v3/projects/PROJECT/timeSeries" \
  --data-urlencode 'filter=metric.type="monitoring.googleapis.com/uptime_check/check_passed"' \
  --data-urlencode "interval.startTime=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --data-urlencode "interval.endTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --data-urlencode "view=FULL" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)"

# Did a notification actually try to publish? (this is the log that
# explains a silent Pub/Sub failure)
gcloud logging read \
  'logName="projects/PROJECT/logs/monitoring.googleapis.com%2Fnotification_channel_events"' \
  --project PROJECT --limit=5 --format="value(timestamp,jsonPayload.summary)"

# Did the failover function run?
gcloud functions logs read dr-demo-dns-failover --region=us-east1 --limit=10 \
  --format="value(timestamp,severity,jsonPayload.message)"

# What does DNS actually say? (query the zone's authoritative server)
# Use the zone's OWN nameservers — they are per-zone, so never hardcode
# one:
#   terraform output -json dns_name_servers | jq -r '.[0]'
dig @$(terraform -chdir=terraform output -json dns_name_servers | jq -r '.[0]') \
  www.YOUR_ZONE CNAME +short

# Simulate failover by hand (no waiting for the alert)
gcloud pubsub topics publish dr-demo-dns-failover-events \
  --message='{"incident":{"state":"open","incidentId":"manual-1"}}'
gcloud pubsub topics publish dr-demo-dns-failover-events \
  --message='{"incident":{"state":"closed","incidentId":"manual-1"}}'
```
