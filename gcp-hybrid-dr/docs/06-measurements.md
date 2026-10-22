# Measurements: Hybrid Cloud Disaster Recovery

Everything in this document was measured against a **live deployment** on
2026-10-21, not estimated. The project `gcp-hybrid-dr` was created, the
Terraform applied, and a real disaster was injected by stopping the
primary VM.

Reproduce it:

```bash
bash src/scripts/disaster-drill.sh \
  --project gcp-hybrid-dr --zone us-east1-b --instance dr-demo-primary \
  --dns-name www.dr-demo.gcp-hybrid-dr.example.com. \
  --resolver ns-cloud-b1.googledomains.com
```

---

## 1. Environment

| Item | Value |
|------|-------|
| Project | `gcp-hybrid-dr` (number 627108056918) |
| Primary | e2-micro, us-east1-b, Debian 12, nginx + gunicorn + Flask + SQLite |
| DR standby | Cloud Run, us-west1, scale-to-zero, nginx maintenance page |
| Backup bucket | `gcp-hybrid-dr-dr-demo-backups` (us-east1, Standard, CMEK) |
| Replica bucket | `gcp-hybrid-dr-dr-demo-backups-replica` (us-west1, Nearline, CMEK) |
| Backup cadence | hourly (`backup_cron = "0 * * * *"`) for the measurement run |
| DNS zone | `dr-demo.gcp-hybrid-dr.example.com.` (no registered domain) |
| Public record | `www.dr-demo.gcp-hybrid-dr.example.com. CNAME` |

---

## 2. RTO — measured, not estimated

The drill injects a real outage (the VM is stopped), then polls the
public name against the zone's **authoritative nameserver** and probes
`/health` on whatever it resolves to. That measures the whole
user-visible path:

```
DNS resolution -> alert detection -> record flip -> connect -> 200 OK
```

<!-- MEASURED-RTO-BLOCK -->

### The measured run

```
[2026-10-21T17:43:18+00:00] stopping dr-demo-primary (simulated disaster)
[2026-10-21T17:43:40+00:00] VM stopped (+22s)
[2026-10-21T17:43:41+00:00] DNS www.dr-demo...example.com. -> primary.dr-demo...example.com.
[2026-10-21T17:50:59+00:00] DNS www.dr-demo...example.com. -> dr-demo-dr-maintenance-...a.run.app.
[2026-10-21T17:50:59+00:00] endpoint answering 200 on /health via dr-demo-dr-maintenance-...a.run.app.
[2026-10-21T17:50:59+00:00] restarting dr-demo-primary
[2026-10-21T17:51:59+00:00] primary healthy again (34.23.59.120)
[2026-10-21T17:54:48+00:00] DNS restored -> primary.dr-demo...example.com. (primary)

=== MEASURED RTO ===
disaster injected : 2026-10-21T17:43:18+00:00
DR serving users  : +461s
path measured     : DNS(www.dr-demo...example.com., via ns-cloud-b1.googledomains.com)
                    -> resolve -> connect -> /health 200
```

**RTO: 461 seconds (7m 41s)** from the VM being stopped to users being
served by the standby. The full round trip — incident open → flip →
serve → incident closed → restore — completed in **11m 30s**.

The corresponding function log:

```
FAILOVER_ACTIVATED: www.dr-demo...example.com. now points at the DR target
FAILOVER_RECOVERED: www.dr-demo...example.com. restored to the primary target
```

### Three independent runs

| Run | Outage injected | Users served | RTO |
|-----|-----------------|--------------|-----|
| 1 | 17:11:41 | 17:19:23 | **462s** |
| 2 | 17:43:18 | 17:50:59 | **461s** |
| 3 | 20:03:46 | 20:11:48 | **482s** |

Three drills, three different times of day, an RTO spread of 21 seconds
(462 / 461 / 482). The variance comes from Cloud Monitoring's own
evaluation latency — the alert window is a fixed 300s, but *when*
Monitoring notices the failure within it is not. That is the mechanism
being consistent, not a lucky sample.

Run 3 was the final verification after the review pass — it ran against
the corrected backup upload, the corrected DNS resolution, and the
rebuilt failover function, and completed the full round trip including
the DNS restore.

> **Honest caveat.** The drill queries the zone's **authoritative**
> nameserver, so it sees the new record as soon as it is committed. A
> user behind a recursive resolver may keep the cached answer for up to
> one TTL (300s). The *user-visible* worst case is therefore
> **482s + up to 300s ≈ 12.7 minutes**; the *infrastructure* RTO — the
> time for the record to change — is 482s. Both numbers are worth
> stating, and the drill reports the one it actually measured.

### Why the RTO is what it is

| Stage | Time | Why |
|-------|------|-----|
| Uptime check interval | 60s | `period = "60s"` on the check config |
| Alert `duration` window | 300s | the policy only opens an incident after 5 continuous minutes of failure — this is what stops a single blip from failing over |
| Metric ingest + evaluation | ~60–120s | Monitoring's own pipeline latency |
| Record flip | ~1–2s | one Cloud DNS `changes.create` call |
| TTL expiry | 0–300s | how long a recursive resolver may keep serving the old answer; the drill queries the authoritative server directly, so it sees the new answer immediately, but a user behind a caching resolver may wait up to one TTL |
| Cloud Run cold start | ~1–2s | the standby is scale-to-zero; the container is tiny |

The dominant term is the **300s alert window**, and that is a deliberate
choice: a 60s window would fail over on a single dropped request.

---

## 3. The cost figure — counted, not estimated

The cost table was wrong for a while, so it is worth showing how the
correct number is arrived at rather than just stating it.

**The KMS line was double-counted.** The original table read
"2 active versions × 2 keys = $0.24". Counted against the live
project:

```
$ gcloud kms keys versions list --location=us-east1 \
    --keyring=dr-demo-backup-keyring --key=dr-demo-backup-key
.../cryptoKeyVersions/1  ENABLED

$ gcloud kms keys versions list --location=us-west1 \
    --keyring=dr-demo-backup-keyring-dr --key=dr-demo-backup-key-dr
.../cryptoKeyVersions/1  ENABLED
```

**2 keys, 1 version each = 2 versions.** KMS bills $0.06 per key
*version* per month, so that is **$0.12/mo**, not $0.24.

**The other error was a period mismatch.** The original "$1.40" was a
two-month total (storage and DNS lines multiplied by 2) presented as a
monthly one. With the line items added up correctly:

| Component | Monthly |
|-----------|---------|
| e2-micro (us-east1, free tier) | $0.00 |
| Cloud Storage — backup (5 GB Standard) | $0.10 |
| Cloud Storage — replica (5 GB Nearline) | $0.05 |
| Cloud KMS (2 key versions) | $0.12 |
| Cloud DNS (1 zone + 1 health check) | $0.26 |
| Cloud Scheduler + Pub/Sub | $0.00 |
| Cloud Functions (3, scale-to-zero) | $0.00 |
| Cloud Run standby (scale-to-zero) | $0.00 |
| Artifact Registry (1 image) | $0.00 |
| **Monthly total** | **$0.53** |
| **Two-month total** | **$1.06** |

Both errors were caught by arithmetic, not by testing. The lesson is
recorded in JOURNEY.md as lesson 12.

---

## 4. RPO — measured

The RPO is the age of the newest backup at the moment of the disaster.

<!-- MEASURED-RPO-BLOCK -->

**Measured RPO: 2.7 hours (2h 41m).**

The newest backup at the moment the drill injected the disaster was
`app-20261021T150147.833Z.db.gz`, taken at **15:01:47 UTC**. The
disaster was injected at **17:43:18 UTC**. The RPO is the gap between
them:

```
17:43:18  (disaster injected)
15:01:47  (newest backup)
   -------
   2h 41m  = 2.7 hours of potential data loss
```

The freshness sentinel independently confirmed the backup was real and
recent — at 15:45:55 it reported the same object as "0.7h old", which is
correct for *that moment* and is **not** the RPO at the time of the
disaster.

> An earlier draft of this document quoted **0.7h** as the RPO. That
> was the sentinel's reading at 15:45, conflated with the RPO. The
> corrected figure is **2.7h**, and it is the number the README and
> JOURNEY now quote.

With the default `backup_cron = "0 2 * * *"` (nightly) the worst case is
~22h and the Day 6 simulation measured 18h. The measurement run used the
hourly schedule (`backup_cron = "0 * * * *"`), which costs **$0 extra**
on an e2-micro that is already inside the free tier.

**The RPO dial is `backup_cron`.** It is a Terraform variable, validated
as a 5-field cron expression, delivered to the VM as instance metadata
and written to `/etc/cron.d/dr-backup` by the startup script. Changing it
to `"0 * * * *"` costs $0 extra on an e2-micro.

---

## 5. Backup pipeline — verified end to end

The backup was not assumed to work; it was verified on the live system.

```
$ bash src/scripts/verify-backup.sh gcp-hybrid-dr-dr-demo-backups
latest backup: gs://gcp-hybrid-dr-dr-demo-backups/backups/app-20261021T150147.833Z.db.gz
app-20261021T150147.833Z.db.gz: OK
OK: checksum verified, gzip intact, integrity_check ok, 5 order rows
backup age: 0h (RPO target: <24h)
```

That single line is the whole chain:

| Step | Checked by |
|------|-----------|
| Consistent snapshot while serving traffic | SQLite online backup API |
| Snapshot is valid before shipping | `PRAGMA integrity_check` in `backup.sh` |
| Compressed | `gzip -9` |
| Checksum manifest written | `sha256sum` |
| Uploaded without corruption | `x-goog-hash: crc32c=...` → GCS validates in transit |
| Downloaded intact | `sha256sum -c` in `verify-backup.sh` |
| gzip not truncated | `gunzip -t` |
| Database structurally sound | `PRAGMA integrity_check` |
| Real data recovered | `SELECT count(*) FROM orders` → 5 rows |

### The write-only guarantee, proven from the VM itself

The whole design rests on one property: **the primary VM can write
backups but cannot read them.** Asserting it in a doc is worth nothing,
so it was checked from inside the VM, using the VM's own service
account:

```
$ gcloud storage ls gs://gcp-hybrid-dr-dr-demo-backups/backups/
ERROR: (gcloud.storage.ls) HTTPError 403:
  dr-demo-primary-sa@gcp-hybrid-dr.iam.gserviceaccount.com does not
  have storage.objects.get access to the Google Cloud Storage object.

$ gcloud storage cat gs://gcp-hybrid-dr-dr-demo-backups/backups/...
ERROR: (gcloud.storage.cat) HTTPError 403: ... storage.objects.get denied
```

The same service account, moments later, **wrote** a new backup
successfully. Write-only, verified in both directions.

> Note: the bucket's IAM policy also lists `roles/storage.legacyBucketOwner`
> for `projectEditor:` / `projectOwner:` — those are GCP's *default
> project-level* bindings, present on every bucket in a project, not
> something this configuration added. The point of the test above is
> that the **VM's own identity** is restricted to `objectCreator` and
> nothing else, whatever the project's other members can do.

---

## 6. Cross-region replication — verified, not assumed

The Storage Transfer Service job replicates the backup bucket to a
Nearline bucket in us-west1. Triggered manually (the project was
created after the daily 04:00 UTC slot had passed):

```
$ gcloud storage ls -l gs://gcp-hybrid-dr-dr-demo-backups/backups/
       633  2026-10-21T18:00:05Z  .../app-20261021T180001.542Z.db.gz
        97  2026-10-21T18:00:07Z  .../app-20261021T180001.542Z.db.gz.sha256

$ gcloud storage ls -l gs://gcp-hybrid-dr-dr-demo-backups-replica/backups/
       633  2026-10-21T18:03:10Z  .../app-20261021T180001.542Z.db.gz
        97  2026-10-21T18:03:07Z  .../app-20261021T180001.542Z.db.gz.sha256
```

Byte-identical, in a different region. Downloading the **replica** and
verifying it independently:

```
$ sha256sum -c app-20261021T180001.542Z.db.gz.sha256
app-20261021T180001.542Z.db.gz: OK
$ sqlite3 app.db "PRAGMA integrity_check; SELECT count(*) FROM orders;"
ok
5
```

The disaster copy is provably restorable.

---

## 7. The automated restore drill — verified live

The weekly drill function was triggered against the live bucket:

```
RESTORE_DRILL_PASS: newest backup downloaded, checksum verified,
gzip intact, integrity ok    order_rows=5  age_hours=0.1
```

and the freshness sentinel, on the same backup:

```
backup fresh: backups/app-20261021T180001.542Z.db.gz is 0.1h old (limit 24h)
```

**No ERROR-severity log entries were emitted by any of the three
functions during the verification window.**

---

## 8. DNS failover — the full round trip

The public record is a CNAME whose two targets are hostnames:

```
www.dr-demo.gcp-hybrid-dr.example.com.  CNAME  primary.dr-demo.gcp-hybrid-dr.example.com.
primary.dr-demo.gcp-hybrid-dr.example.com.  A  34.23.59.120      (the on-prem VM)
```

and during an incident:

```
www.dr-demo.gcp-hybrid-dr.example.com.  CNAME  dr-demo-dr-maintenance-br4dukadqa-uw.a.run.app.
```

Resolved against the authoritative nameserver — **no registered domain
required**:

```bash
$ dig @ns-cloud-b1.googledomains.com www.dr-demo.gcp-hybrid-dr.example.com CNAME +short
dr-demo-dr-maintenance-br4dukadqa-uw.a.run.app.
```

Function logs from the same drill:

```
FAILOVER_ACTIVATED: www.dr-demo.gcp-hybrid-dr.example.com. now points at the DR target
FAILOVER_RECOVERED: www.dr-demo.gcp-hybrid-dr.example.com. restored to the primary target
```

---

## 9. What the automated chain looks like

Nothing in the failover path is manual. The complete path, verified
end-to-end:

```
VM stopped
  -> uptime check /health fails (3 US regions)
  -> monitoring.googleapis.com/uptime_check/check_passed = False
  -> "Primary site DOWN" alert policy, duration 300s
  -> incident opens
  -> Pub/Sub notification channel publishes the incident JSON
  -> Eventarc triggers the dns-failover function
  -> function probes the standby's /health, then rewrites the CNAME
  -> users resolve www.<zone> to the Cloud Run standby
  -> (VM restarted) -> check passes -> incident closes
  -> function rewrites the CNAME back to the primary
```

Every arrow in that chain was exercised by the drill.

---

## 10. Terraform drift — three sources of permanent churn

A project that is meant to be re-applied (and audited) has to produce
a **clean plan** on an unchanged codebase. Three things broke that, and
all three were found by running `terraform plan` repeatedly rather than
once.

### 10.1 The primary VM was being REPLACED every time an admin SSHed in

`gcloud compute ssh` **appends** the caller's key to the instance's
`ssh-keys` metadata. That value is part of the instance fingerprint, so
Terraform saw a difference and wanted to **replace the primary site** —
because someone logged in.

Replacing the primary site because an administrator authenticated is
not acceptable behaviour for a disaster-recovery system, and it would
have silently destroyed the running app on every SSH.

The drift is additive (a key is added, never removed), so the
provisioned key stays in place. The fix is to ignore that one field:

```hcl
lifecycle {
  ignore_changes = [metadata["ssh-keys"]]
}
```

### 10.2 The uptime check's region codes

The API returns `USA_OREGON`; the provider normalises it to
`USA-OREGON` when diffing. Whichever form is configured, the plan
showed a difference that no apply could settle. Ignored, with a comment
explaining why.

### 10.3 The dashboard JSON

The Monitoring API injects `targetAxis` into every dataSet, stores the
column count as a **string** (`"12"`, not `12`), and adds an `etag` and
a `name` at the top level. The first two are now declared so they
match; the server-managed pair cannot be set, so the attribute is
ignored — with a note that a widget change needs
`terraform apply -replace=google_monitoring_dashboard.dr_posture`.

**Result: `terraform plan` on a freshly applied project reports no
changes at all.** A plan that always shows a diff is a plan nobody
reads, which is how a real drift hides in plain sight.

---

## 11. A cost leak found by reading the pricing page

The cost table was correct at $0.12/mo for KMS — but only *today*. The
KMS pricing page says a key version is billed while it is **Enabled,
Disabled, or Scheduled for destruction**, and the rotation docs say
"rotating a key does not automatically disable or destroy any existing
key versions".

So `rotation_period = 7776000s` on its own is a slow, unbounded cost
leak: every 90 days a version is added, nothing ever removes it, and
the cost climbs whether the project is being used or not.

Measured on a scratch key with a 1-day rotation period:

```
$ gcloud kms keys versions list --keyring=<probe> ...
1  ENABLED  2026-10-21T09:56:52Z
2  ENABLED  2026-10-22T06:27:51Z     <- new primary
```

**Both** versions are billable. `destroy_scheduled_duration` does not
help: it only controls how long a version stays in `DESTROY_SCHEDULED`
after something has *explicitly* destroyed it.

**The fix** is a new Cloud Function,
`src/functions/key-version-retirement`, run monthly by a Scheduler job:
it destroys key versions that are no longer primary and are older than
the backup retention window. The retention window is a hard floor —
destroying a key version makes the data it encrypted unreadable.

**Verified live.** With a 1-day-old non-primary version and a zero-day
retention window, the sweep destroyed it and left the primary alone:

```
KEY_VERSION_RETIRED: superseded key version destroyed
   version: .../cryptoKeyVersions/1   previous_state: 1
```

```
after:  1  DESTROY_SCHEDULED      <- destroyed, and DESTROYED is free
        2  ENABLED                <- the primary, untouched
```

With the real 30-day window it correctly destroys nothing:
`KEY_VERSION_RETIRE_PASS ... destroyed=0 retention_days=30`.

**Three API bugs were caught only by running it**, not by the unit tests:
`key_ring_path()` needs separate location and keyring arguments;
`list_crypto_keys` / `list_crypto_key_versions` are the real method
names; and `key.primary` is a CryptoKeyVersion **object**, not a name —
comparing `version.name == key.primary` silently never matches, which
would have let the function destroy the primary version and break every
subsequent write. The unit tests now pin all three.

### 11.1 And then it destroyed live data — which is how the real bug was found

The function was deployed and, during verification, it destroyed a key
version that was **still the one encrypting every live backup**.

```
$ bash src/scripts/verify-backup.sh gcp-hybrid-dr-dr-demo-backups
ERROR: (gcloud.storage.cp) HTTPError 400: Cloud KMS key is disabled,
destroyed, or scheduled to be destroyed.
```

The cause was a wrong idea about what "old" means. The first
implementation compared a version's **create time** against the
retention window. But a version's create time is when it became
*primary* — not when it stopped being primary. A version created 90 days
ago may have been primary until yesterday, and the backups written in
that window are still restorable. Destroying it makes them permanently
unreadable, and the version *looked* old.

The age that matters is the **supersession** time: the moment the
*next* version was created. A version is retirable only once

```
now > superseded_at + retention_window
```

**Recoverable only because of the 30-day soft-delete window.** The
version was restored (`DESTROY_SCHEDULED` → `DISABLED` → `ENABLED`) and
made primary again; the backups verified immediately afterwards:

```
OK: checksum verified, gzip intact, integrity_check ok, 5 order rows
```

In production there is no second chance: the version is destroyed and
every backup encrypted under it is gone. The regression test
`test_just_superseded_version_is_not_destroyed` now pins this — a
version superseded *yesterday* must survive the window, however old its
create time is.

This is the single most valuable thing the day produced, and it is
worth stating plainly: **a function that destroys key material must be
tested against the data it protects, not against its own inputs.**

### 11.2 Read the pricing page, then measure it

This is the third time in this project that a cost or correctness claim
turned out to depend on a platform behaviour I had read about rather
than measured. The pattern is consistent: **read the pricing page, then
measure it.**

---

## 12. Findings from the live run

The deployment was the point. It surfaced bugs that no amount of code
review had:

| # | Finding | Fix |
|---|---------|-----|
| 1 | `gcloud storage cp` reads the destination before writing → 403 with write-only IAM. **Backups had never succeeded.** | Upload via the JSON API's `uploadType=media`, which creates without reading |
| 2 | `roles/dns.resourceRecordsAdmin` does not exist on GCP; Cloud DNS silently drops the binding | Project-level custom role with only the record-set permissions |
| 3 | Zone-level Cloud DNS IAM returns HTTP 500 on this account | Move the grant to the project level |
| 4 | `uptime_check/check_failed` does not exist while healthy → the alert policy could not even be created | Filter on `uptime_check/check_passed` and test for False |
| 5 | The Cloud Monitoring **notification** service agent is a different account from the monitoring service agent → notifications silently failed with PERMISSION_DENIED | Grant `roles/pubsub.publisher` to `gcp-sa-monitoring-notification` |
| 6 | `default-allow-ssh` allowed SSH from `0.0.0.0/0`, defeating the admin-IP-only rule | Import it and set `disabled = true` |
| 7 | `retention_period` was a string; the provider needs a number of seconds | Numeric seconds |
| 8 | `kms.googleapis.com` is not a real service name | `cloudkms.googleapis.com` |
| 9 | Terraform's `replace()` does not match regular expressions → the CNAME target kept its `https://` | `trimprefix` / `trimsuffix` |
| 10 | The Pub/Sub notification channel label key is `topic`, not `topic_id` | Corrected |
| 11 | A CNAME cannot exist at a zone apex | Public record moved to `www.<zone>` |
| 12 | The billing budget currency must match the billing account's | `billing_currency` variable |
| 13 | Backup object names had second granularity → two runs in the same second collided, and write-only IAM cannot overwrite | Millisecond precision |
| 14 | The upload checksum was not CRC32C (it was zlib's IEEE CRC-32) **and** was sent in an `x-goog-hash` header, which GCS does not validate | Real CRC32C (Castagnoli), sent in the `crc32c` metadata field, where GCS checks it |
| 15 | `startup.sh` never installed the Google Cloud CLI, which `backup.sh` needs; the base `debian-12` image does not ship it | Install `google-cloud-cli` from Google's apt repo |
| 16 | `startup.sh` used `sudo -u www-data`; Debian 12 minimal images have no `sudo` | `runuser -u www-data` (util-linux, always present) |
| 17 | The DNS failover IAM binding had no `count` guard, so an empty `dns_failover_role_id` reached the IAM API and failed the apply — despite the variable's docs saying it would be skipped | `count = var.dns_failover_role_id == "" ? 0 : 1` |
| 18 | The log sink filter referenced `<prefix>-deny-all-ingress`, but the rule is `<prefix>-primary-vpc-deny-all-ingress` — the sink had never matched a log line | Corrected; verified against live DENY events |
| 19 | The billing budget had no `all_updates_rule`, so it notified nobody — a report, not a guardrail | Wired to the project's channels, gated behind `budget_notify` because this account's API rejects the field |
| 20 | `default-allow-ssh` could not be created on a fresh project (it already exists) | Terraform `import` block, so the first apply takes it over automatically |
| 21 | The Flask app interpolated database values into HTML with no escaping | `markupsafe.escape` on every value |
| 22 | Both Cloud Functions materialised the entire bucket listing | Stream it and keep only the newest |
| 23 | Rotated KMS key versions were never retired — every 90 days a new billed version appeared and nothing removed it, forever | A monthly `key-version-retirement` function destroys superseded versions older than the backup retention window. **Verified live.** |

A fourteenth class of bug was in the **drill script** rather than the
platform: its resolver and probe logic was wrong four separate ways
(`dig +short` returns a CNAME target; the authoritative server does not
resolve out-of-zone names; in-zone names are invisible to the public
resolver; the standby is TLS-only and the primary is not). Each one
turned a *working* failover into a reported "timeout". They are fixed
and pinned by 9 unit tests, because a measuring instrument that lies is
worse than no instrument.

### Two account-level limitations found along the way

These are not project bugs, and are documented rather than hidden:

| Limitation | What was measured |
|------------|-------------------|
| Cloud Logging → Cloud Storage export delivers nothing | A scratch sink with **no filter at all**, pointing at a freshly created bucket, also produced zero objects. The filter itself was verified to match live entries. The DENY events are generated and queryable in Cloud Logging; only the *export* is unavailable. |
| The Cloud Billing Budget API rejects `allUpdatesRule` | "Unknown name \"allUpdatesRule\" at 'budget': Cannot find field." on v1 **and** v1beta1, for every payload variant (empty rule, channels only, with schemaVersion, with project recipients). The budget still records thresholds and notifies the account's default IAM recipients. |
