# MISSING.md — gcp-hybrid-dr

> Audit date: 2026-08-17 · updated 2026-08-21 · enhancement pass 2026-08-24
> · **live deployment pass 2026-10-21** · **final scope pass 2026-10-21**
> Cross-reference: `/var/home/ansh/Projects/GCP/PORTFOLIO_AUDIT.md`

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ❌ | Not built, not documented — real gap |
| ✅ | Resolved since the last audit |
| 🔄 | Tech pivot from plan — intentional, keep the JOURNEY entry |
| 📸 | Needs a human at a keyboard (screen capture) |
| ⏭️ | Deliberately out of scope, with a stated reason |

---

## Scope statement — what this project is and is not

The project is **complete**. The two items that were still open after the
live deployment are closed as follows:

| Item | Outcome |
|------|---------|
| Screen recording | 📸 **The only remaining human task.** Everything it would show now exists, is measured, and is verified. It is a capture, not a build. |
| Cross-project backup replica | ⏭️ **Deliberately skipped, by decision, for budget reasons.** The design is written down and the in-project protections that ship instead are documented and verified. |

Nothing else is outstanding. Every other capability in the plan is
built, deployed, running, and measured — see
[docs/06-measurements.md](docs/06-measurements.md).

---

## 📸 The screen recording — the one remaining human task

**Status: everything it would show now exists and is verified.** The
recording is a capture of a working system, not a build of a missing
one.

What to capture (2 minutes, one command):

```bash
bash src/scripts/disaster-drill.sh --project YOUR_PROJECT \
  --zone us-east1-b --instance dr-demo-primary \
  --dns-name www.YOUR_ZONE. \
  --resolver $(terraform -chdir=terraform output -json dns_name_servers | jq -r '.[0]')
```

The drill produces the whole story on screen, with real timings:

| Moment | What the viewer sees | Measured value |
|--------|----------------------|----------------|
| 0:00 | The drill stops the primary VM — a real outage | — |
| 0:00 | `dig @ns-cloud-... www.<zone> CNAME` → `primary.<zone>` | healthy |
| ~7:00 | The alert fires, the CNAME flips | **461–482s** |
| ~7:00 | `dig` again → `<standby>.a.run.app`; the standby answers `{"status":"ok","site":"dr"}` | users are being served |
| ~8:00 | The drill restarts the VM | primary healthy |
| ~11:00 | The CNAME flips back to `primary.<zone>` | full round trip |

Cut in a second clip: `bash src/scripts/verify-backup.sh <bucket>` →
`OK: checksum verified, gzip intact, integrity_check ok, 5 order rows`.

Why it is worth doing: it is a **real** outage with a **real** number,
and the failover is **real** automation rather than a diagram. That
distinction is the whole point of the project.

---

## ⏭️ The cross-project backup replica — deliberately skipped

**Decision: implemented as designed in the docs, skipped in the
deployment, because a second billable GCP project did not fit the
budget.**

### What it was

Replicate the backup bucket into a **second GCP project**, so that an
actor who compromises the first project — with project-level IAM, or
with the ability to delete a bucket — still cannot destroy the backups.
The second copy lives under a different project, a different billing
scope, and ideally a different owner.

### Why it was skipped

| Reason | Detail |
|--------|--------|
| **Budget** | The whole portfolio shares one **$300 trial credit**. A second project means a second copy of every billable resource. The project's own budget is **≤ $2/month** for the entire 7-project portfolio, and the first project already costs $0.53/mo. A second project would roughly double the fixed costs (KMS keys are per-project and per-region, the Cloud DNS zone is per-zone, the second bucket is a second set of storage) for a *control* improvement, not a *capability* one. |
| **Blast radius** | Creating a project and linking it to billing is an account-owner action. On a shared trial budget, a mistake (or a runaway resource) affects every other project in the portfolio, not just this one. |
| **It was a decision, not a blocker** | Nothing about the design was unknown. The Terraform work — a second `google_storage_bucket`, a per-bucket `project_id`, a KMS keyring in the second project, and a Storage Transfer Service job with a cross-project sink — is understood and was written up before the decision was made. |

### What ships instead, and is verified

The threat model behind the cross-project copy is *"an actor with
project-level IAM destroys the backups"*. The in-project controls
answer most of that, and unlike a second project they cost nothing:

| Control | What it stops | Status |
|---------|---------------|--------|
| **Write-only `objectCreator` on the VM's SA** | The primary (the most likely attacker — ransomware on the box) cannot list, read, overwrite or delete backups. | ✅ Verified from inside the VM: `gcloud storage ls` → HTTP 403. The same identity successfully *writes* backups. |
| **Bucket-level retention policy** | A principal with `storage.admin` cannot delete backups younger than the retention window. | ✅ Live on both buckets. `lock_backup_retention = true` makes it permanent against *everyone*, including the project owner. |
| **Object versioning** | An accidental overwrite is recoverable from a prior generation. | ✅ Live on both buckets. |
| **Cross-region replication (Storage Transfer Service)** | A regional outage in us-east1 does not take the backups with it. | ✅ Verified: the us-west1 replica is byte-identical and independently restorable. |
| **CMEK encryption with a 90-day rotation** | A stolen copy of the bucket is useless without the key, and the key version rotates. | ✅ Live; the GCS service agent holds the key, not the writer. |
| **The restore drill** | A backup that exists but cannot be restored is caught weekly, automatically. | ✅ Verified live: `RESTORE_DRILL_PASS`, checksum verified, 5 order rows. |

**What is genuinely still exposed:** a principal with enough IAM in the
*project* to delete the bucket and its objects, ignoring the retention
policy. That is a real gap and the cross-project copy is the honest fix
for it. It is a gap in a project whose other protections are
demonstrated rather than asserted.

### The design, written down so it is a config change not a rewrite

Should the budget ever allow it, this is the shape of the work:

```hcl
# In the second project — a separate Terraform state, separate billing.
resource "google_storage_bucket" "backup_replica" {
  name     = "${var.replica_project_id}-dr-backups"
  location = var.dr_region
  # ... CMEK with a key in the SECOND project's keyring, so the second
  # copy is not readable with the first project's key either.
  encryption { default_kms_key_name = google_kms_crypto_key.replica.id }
}

# In THIS project — a transfer job with a cross-project sink.
resource "google_storage_transfer_job" "cross_project_replica" {
  transfer_spec {
    gcs_data_source { bucket_name = google_storage_bucket.backup.name }
    gcs_data_sink   { bucket_name = "projects/${var.replica_project_id}/buckets/${var.replica_project_id}-dr-backups" }
  }
  # The STS service agent in THIS project needs objectViewer on the
  # source and writer on the sink — granted cross-project by IAM.
}
```

The parts that need thought (and are the reason it is not a
30-minute change): a second KMS keyring in the second project, the
cross-project IAM grants for the Storage Transfer Service agent in
both directions, and a second Terraform state with its own bootstrap.

### The honest one-line summary

> *A second project would strengthen the backup story against
> project-level compromise, and it is designed but not deployed — the
> $300 shared trial budget did not stretch to it. What ships instead is
> write-only IAM, locked retention, versioning, cross-region
> replication and a weekly restore drill, each verified.*

---

## ✅ Resolved by the live deployment (2026-10-21)

The project was **deployed for real** and a real disaster was injected.
That exposed 32 bugs that no amount of code review had found. See
[docs/06-measurements.md](docs/06-measurements.md) and JOURNEY.md
Day 10.

### The headline fixes

- **The backup pipeline had never once succeeded** — `gcloud storage cp`
  reads the destination before writing it, which write-only IAM forbids.
  The upload moved to the Cloud Storage JSON API, so the write-only
  guarantee survives end to end.
- **DNS failover works without a registered domain** — a Cloud DNS zone is
  authoritative for its own name, so the failover could be demonstrated
  and measured for free.
- **The upload checksum was not CRC32C** and was not being validated; it
  is now a real CRC32C sent where Cloud Storage checks it.
- **`default-allow-ssh` was open to `0.0.0.0/0`**, defeating the
  "admin-IP-only" SSH claim the docs had made since Day 1.
- **RPO and RTO are measured** — 461–482s across three live drills.

---

## ✅ Resolved (2026-08-21 hardening pass)

### Architecture diagram
- **Was:** ASCII art only in README and `docs/01-architecture.md`.
- **Now:** hand-authored SVG rendered to PNG at `assets/architecture.png`
  (source: `assets/architecture.svg`), linked from the top of the README's
  Architecture section.

### Checklist items closed the same day (see gcp-checklist.md for detail)
- **6.2 / 9.3 Remote state:** partial GCS backend (`terraform/backend.tf`) +
  `scripts/bootstrap-state.sh` (versioned bucket, noncurrent versions expire
  after 30 days).
- **8.1 Labels:** root `labels` var wired through all modules onto every
  labelable resource (VM, buckets, KMS keys, Pub/Sub topic, Cloud Run,
  Artifact Registry).
- **7.1 Alerts:** VM CPU >90%/10min, uptime-failure alert, monthly billing
  budget (50/90/100% thresholds, gated behind `billing_account_id`).
- **7.2 Log sink:** filtered export of firewall DENY events only → GCS bucket
  with 30-day lifecycle.
- **7.3 Uptime check:** `/health` probed from 3 US regions + failure alert.

---

## ✅ Resolved (2026-08-24 enhancement pass — see JOURNEY.md Day 9)

### DNS failover made real *(was a latent bug)*
- **Was:** two `google_dns_record_set` resources with identical name+type and
  no routing policy — a duplicate-RRset conflict that never applied (module
  gated behind `enable_dns = false`). Comments claimed "weight 100 / weight 0"
  that existed nowhere.
- **Now:** ONE active A record + alert-driven failover: `primary_down` alert →
  dedicated Pub/Sub channel → `dns-failover` Cloud Function rewrites the record
  to DR targets on incident open and restores it on close. Function SA holds
  only `roles/dns.resourceRecordsAdmin` on that one zone — **a role that
  turns out not to exist on GCP**, which is why the whole design was
  rebuilt on 2026-10-21. Honest limits kept visible: without the Cloud Run
  domain mapping there are no stable DR IPs, and the function logs
  `FAILOVER_TARGET_MISSING` loudly instead of pretending.
  *(Superseded on 2026-10-21 — see below.)*

### Automated restore drill
- **Now:** weekly Scheduler → Pub/Sub → `restore-drill` function: downloads the
  newest backup, verifies its sha256 manifest, gunzips, runs SQLite
  integrity_check + row count. Failures emit `RESTORE_DRILL_FAIL` → log-based
  metric → email alert. "A backup you haven't restored is a hope" is now an
  automated, monitored claim.

### RTO measurement automation
- **Now:** `src/scripts/disaster-drill.sh` stops the VM, polls until the DR
  target answers `/health`, prints a timestamped timeline + measured RTO,
  restarts the VM (trap guarantees restart even on failure), waits for primary
  health before exiting.

### Backup cadence configurable (the RPO dial)
- **Now:** `backup_cron` variable (validated 5-field cron) → VM metadata →
  `/etc/cron.d/dr-backup`. Hourly = RPO <1h at $0 extra. Documented limit:
  startup scripts run once; changes apply on VM recreation.

### Bucket-level retention policies
- **Now:** `retention_policy` on both backup buckets (period =
  `backup_retention_days`, matching the lifecycle rule). Optional
  `lock_backup_retention` makes windows permanent even against project owners
  — off by default because locking also blocks `terraform destroy` until
  backups age out.

### DR-posture Monitoring dashboard
- **Now:** Terraform-managed `google_monitoring_dashboard`: uptime-check
  failures, VM CPU, RPO breaches, restore-drill failures — four charts, free
  tier, survives project rebuilds.

---

## ✅ Resolved by the live deployment (2026-10-21) — the substantive rewrite

Everything in this section was found by **running the thing**, not by
reading it. Details and the full list of 32 bugs:
[docs/06-measurements.md §12](docs/06-measurements.md).

### The DNS failover was rebuilt — CNAME, and no domain required
- **Was:** an A record rewritten by a function whose IAM role
  (`roles/dns.resourceRecordsAdmin`) **does not exist on GCP**, on a zone
  whose IAM API returns HTTP 500, behind a flag that was `false`.
- **Now:** the public record is a **CNAME** between two hostnames
  (`primary.<zone>` ⇄ `<standby>.a.run.app`), so the target can never go
  stale and the record type never changes. The failover function has a
  **custom least-privilege project role** (only record-set and change
  permissions — narrower than `roles/dns.admin`), and **probes the standby's
  `/health` before repointing DNS**, refusing to fail over into an
  unreachable standby.
- **No registered domain is required:** a Cloud DNS zone is authoritative for
  its own name, so its nameservers answer queries directly. The whole
  failover path can be demonstrated and measured for free.
- **Verified live:** incident open → CNAME flips to the standby; incident
  closed → CNAME restored to the primary.

### The backup pipeline now actually works
- **Was:** `gcloud storage cp` reads the destination before writing it, so
  under the write-only `objectCreator` binding **every upload 403'd**. The
  pipeline had never once succeeded.
- **Now:** the upload uses the Cloud Storage JSON API's `uploadType=media`
  endpoint, which creates the object without reading the destination, and
  keeps the CRC32C in-transit validation via `x-goog-hash`. The write-only
  guarantee survives end to end.
- **Verified live:** backup uploaded, then downloaded by an admin script,
  sha256 verified, gunzip verified, `integrity_check` = ok, order rows
  recovered.

### The alert pipeline now actually fires
- **Was:** the policy filtered on `uptime_check/check_failed`, a metric that
  only exists **after** a check fails — so the policy could not even be
  created. And notifications silently failed with PERMISSION_DENIED because
  the wrong service agent held the publisher role.
- **Now:** the policy filters on `uptime_check/check_passed` and tests for
  False; Terraform manages `roles/pubsub.publisher` on the failover topic for
  the **notification** service agent (a different account from the ordinary
  monitoring agent).
- **Verified live:** the alert opened, the Pub/Sub message carried the full
  incident payload, and the function acted on it.

### The SSH posture claim is now true
- **Was:** the docs claimed "SSH: admin-IP-only", but GCP's
  `default-allow-ssh` rule — created automatically with every custom-mode
  VPC — allowed `tcp:22` from `0.0.0.0/0` to every instance.
- **Now:** the rule is imported into Terraform and explicitly
  `disabled = true`.

### RPO and RTO are measurements, not estimates
- **Now:** [docs/06-measurements.md](docs/06-measurements.md) records the
  live run — the drill timeline, the measured RTO, the verified backup
  chain, and the RPO with the hourly cadence actually used.

### The project has tests
- **Now:** 74 unit tests over all three Cloud Functions, the Flask app, the shell backup
  pipeline, including a real SQLite → gzip → sha256 → upload round trip
  against a stubbed GCS. They caught two real bugs before the deployment
  ever ran (same-second object-name collision; `--help` exiting 2).

---

## 🔄 Pivots (intentional — JOURNEY entries exist)

| Pivot | Plan | Reality | Verdict |
|-------|------|---------|---------|
| VM cron job for backup | Plan used Cloud Scheduler → Cloud Function | `backup.sh` cron on the VM itself | More realistic for "on-prem" simulation — a real on-prem server would use cron, not a cloud scheduler. Good pivot. Well documented. |
| Storage Transfer Service for cross-region replication | Plan used simple bucket copy | STS (server-side, no VM credentials needed) | Upgrade — more secure (no egress credentials on the VM) and more realistic. |
| Backup freshness Cloud Function sentinel | Not in plan | Added (Scheduler → Pub/Sub → Function) | Exceeds plan — active RPO monitoring rather than passive. |
| JSON API upload instead of `gcloud storage cp` | Plan used the gcloud CLI | Cloud Storage JSON API `uploadType=media` | Forced by the write-only IAM design — and better for it. The CLI's read-before-write is incompatible with "the primary cannot read its own backups". |
| Custom project role for the DNS function | Plan used a predefined role | `drFailoverDnsAdmin` (10 permissions) | The predefined role does not exist; the custom one is narrower than `roles/dns.admin` and actually grants anything. |
| CNAME failover instead of A-record rewriting | Plan rewrote A records to Cloud Run front-end IPs | CNAME between hostnames | The A-record version would have gone stale — Google's front-end IPs rotate. The CNAME version cannot. |

---

## ✅ Already Complete

- e2-micro primary site: Flask + nginx + SQLite, `/health` endpoint
- `backup.sh`: SQLite online backup → gzip → sha256 → CRC32C-validated upload
- Cloud Storage: CMEK-encrypted, versioned, 30-day retention, write-only SA
- Cross-region replica: Storage Transfer Service → Nearline bucket (us-west1)
- Cloud DNS: CNAME failover driven by the `primary_down` alert (no domain needed)
- Cloud Run DR: "Under Maintenance" page, scale-to-zero
- RPO/RTO **measured** on live infrastructure (see docs/06-measurements.md)
- Ransomware simulation: JOURNEY.md Day 6; bucket retention policies (Day 9);
  write-only IAM proven end to end (Day 10)
- Backup freshness sentinel: Scheduler → Pub/Sub → Cloud Function → RPO breach alert
- Weekly automated restore drill: download → sha256 → integrity_check → alert on failure
- Terraform modules: `primary-site`, `backup`, `dr-site`, `dns`
- GitHub Actions CI: fmt, validate, Trivy, ShellCheck, **pytest**, ruff
- 74 unit tests over the functions, the app, the backup pipeline and the drill's DNS/probe helpers
- All 5 `docs/` files + `docs/06-measurements.md`
- JOURNEY.md (10 days, options matrices, FinOps day, hardening passes, deployment day)
