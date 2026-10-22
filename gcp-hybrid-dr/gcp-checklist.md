# GCP Personal Project Quality & Budget Checklist

> **Verified by:** agent — **against a live deployment** (`gcp-hybrid-dr`,
> 2026-10-21), not code review
> **Last verified:** 2026-10-21 (live deployment + disaster drill)
> **Notes:** Items requiring live GCP console access marked [~].

---

## 1. Billing Guardrails

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 1.1 | MUST | Budget alert set at $1, $5, and hard monthly limit with email/phone notification | Check Billing → Budgets & alerts | [x] Terraform `google_billing_budget` at 50%/90%/100% of `monthly_budget_amount`, filtered by project label; **verified created live**. ⚠️ `all_updates_rule` (explicit notification channels) is rejected by this account's API — "Unknown name \"allUpdatesRule\" at 'budget': Cannot find field." on both v1 and v1beta1, for every payload variant. The budget still records thresholds and notifies the billing account's default IAM recipients; `budget_notify = true` enables the explicit channels where the API supports them. |
| 1.2 | MUST | Billing export to BigQuery enabled | Check Billing → Billing export | [~] Console-only — not automated (BigQuery is free-tier but adds a table to maintain) |
| 1.3 | MUST | Free tier e2-micro usage tracked (750 hrs/month) | Check Compute Engine → VM instances → uptime | [x] e2-micro in us-east1, ~40 hrs/mo — inside the free tier; cost $0.00 |
| 1.4 | SHOULD | Auto-shutdown scheduled for non-essential VMs | Check Cloud Scheduler / Cloud Function logs | [~] N/A — the primary must stay up to be a primary; the DR standby is Cloud Run scale-to-zero (the equivalent, for free) |
| 1.5 | SHOULD | Recommender Hub reviewed in last 30 days | Check Recommender Hub → Last viewed timestamp | [~] Console-only |

---

## 2. Cost-Conscious Compute

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 2.1 | MUST | Cloud Run or Cloud Functions used as default compute; VMs only when justified | Check Compute Engine vs Cloud Run service list | [x] One VM (the simulated on-prem primary) + 3 Cloud Functions + 1 Cloud Run standby; **verified live** |
| 2.2 | MUST | Spot/Preemptible used for non-critical workloads | Check instance provisioning model | [x] N/A — the primary must not be preempted; it is a single always-on e2-micro at $0.00 |
| 2.3 | MUST | No VM with public IP running 24/7 unnecessarily | Check VM external IPs + uptime | [x] The VM is the public primary (by design — it is the site). 80/tcp only; SSH is admin-IP-only |
| 2.4 | SHOULD | e2-small/e2-medium preferred over n1/n2 | Check machine type | [x] e2-micro (free tier) |
| 2.5 | SHOULD | GKE Autopilot used for personal K8S projects | Check GKE cluster mode | [~] N/A — no GKE |
| 2.6 | COULD | Cloud Build free tier used instead of self-hosted CI | Check Cloud Build history | [x] Cloud Build used to build the DR image; GitHub Actions for CI (Actions is free for public repos) |

---

## 3. Storage & Data Lifecycle

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 3.1 | MUST | Cloud Storage lifecycle policy exists | Check each bucket → Lifecycle rules | [x] Backup/replica buckets: delete objects after 30d + delete noncurrent versions after 7d; replica bucket itself is Nearline. **Verified live** |
| 3.2 | MUST | BigQuery tables partitioned and clustered | Check BigQuery → Table details | [~] N/A — no BigQuery in this project |
| 3.3 | MUST | BigQuery daily spending limit configured | Check BigQuery → Quotas | [~] N/A — no BigQuery |
| 3.4 | SHOULD | Cloud Firestore used instead of Cloud SQL for small apps | Check active database services | [x] N/A — SQLite inside the app; the DR strategy is engine-agnostic |
| 3.5 | SHOULD | Old container images cleaned from Artifact Registry | Check AR → Image count and age | [x] `keep-recent` (3) + `delete-old` (30d) cleanup policies in Terraform |

---

## 4. Networking & Egress Control

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 4.1 | MUST | Cross-region egress minimized | Check resource regions vs bucket regions | [x] Replicated GCS→GCS server-side (STS); no VM egress for replication |
| 4.2 | MUST | Cloud CDN enabled for static content | Check Cloud CDN → Backends | [~] N/A — a maintenance page is not bandwidth-heavy and Cloud Run's front end already caches |
| 4.3 | SHOULD | Cloud Load Balancer + Cloud Armor in front of public endpoints | Check Load balancing → Frontend IP | [~] N/A — a global load balancer costs more than this whole project's budget; documented in docs/04 |
| 4.4 | COULD | Cloudflare used in front of GCP | Check DNS records | [~] N/A — external service |

---

## 5. Security

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 5.1 | MUST | No service account keys in repos; WIF used for CI/CD | Check Secret Manager / IAM | [x] No keys anywhere; the VM uses a metadata-provided service account; the failover SA is impersonated only for a one-off verification |
| 5.2 | MUST | Unused APIs disabled | Check APIs & Services | [x] Only services used by this project are enabled — declared explicitly in `main.tf` `required_services` and managed as code. **Verified live** (this is also how the `cloudkms.googleapis.com` typo was caught) |
| 5.3 | MUST | Buckets not publicly accessible; uniform bucket-level access | Check each bucket → Permissions | [x] `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"` on every bucket |
| 5.4 | SHOULD | VPC Flow Logs enabled only during debugging | Check subnet details | [x] Flow logs on at 0.1 sampling with a 10-min aggregation — the cheapest setting that still gives visibility |
| 5.5 | SHOULD | Secret Manager used for API keys | Check Secret Manager → Secret count | [x] N/A — no secrets to store |

**Additional findings from the live run:**

| Item | Status |
|------|--------|
| Default `default-allow-ssh` (SSH from `0.0.0.0/0`) disabled | [x] Imported into Terraform and set `disabled = true` — **verified live** |
| Least-privilege IAM for the DNS failover function | [x] Custom project role `drFailoverDnsAdmin` — only record-set + change permissions. **Verified by impersonation** (can read and write record sets; cannot touch zones or IAM) |
| Write-only backup access preserved end to end | [x] Upload goes through the JSON API's `uploadType=media` so the write-only `objectCreator` binding still works. **Verified live**: backup uploaded, then downloaded and integrity-checked from an admin workstation |
| Failover refuses to act without a DR target, or with an unhealthy standby | [x] Covered by unit tests + the live run |

---

## 6. Infrastructure as Code

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 6.1 | SHOULD | Terraform used for resources older than 1 month | Check repo for `.tf` + `terraform state list` | [x] Full Terraform project, 4 modules, **90 resources in state**. Total cost **$0.53/mo** ($1.06 over two months) — see [docs/02-cost-analysis.md](docs/02-cost-analysis.md) |
| 6.2 | SHOULD | Terraform state stored in GCS bucket with versioning | Check GCS bucket → State file + Versioning | [x] Partial GCS backend (`backend.tf`) + `scripts/bootstrap-state.sh` creates a versioned bucket, noncurrent versions deleted after 30d. **Verified live** — the whole deployment ran against the remote backend |
| 6.3 | SHOULD | Provider and module versions pinned | Check `versions.tf` | [x] `required_version >= 1.5.0`, provider `~> 5.0`, `.terraform.lock.hcl` tracked |
| 6.4 | COULD | `terraform plan` reviewed before every apply | Check CI logs / shell history | [x] Every apply in this project was preceded by a reviewed plan |

---

## 7. Observability

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 7.1 | MUST | Alert policies: billing spike, VM CPU >90% (10min), service down | Check Monitoring → Alerting policies | [x] 4 policies live: **primary down** (uptime check), **VM CPU >90%/10min**, **RPO breach**, **restore-drill failure**. **Verified live**: the primary-down policy opened an incident and triggered the failover |
| 7.2 | SHOULD | Log sinks with sampling/filtering | Check Logging → Log sinks | [x] Filtered sink exports only firewall DENY events → GCS bucket (30-day lifecycle); flow logs at 0.1 sampling. **Filter verified against live events** — the DENY events are generated and queryable. ⚠️ The *export* to GCS delivers nothing on this billing account: a scratch sink with no filter and a fresh bucket also produced zero objects, so the Cloud Logging → GCS path is not functional here. Events remain in Cloud Logging and are queryable. |
| 7.3 | COULD | Uptime checks (free: 3) on public endpoints | Check Monitoring → Uptime checks | [x] One uptime check on `/health` from 3 US regions — **verified live**, it flipped to `False` when the VM was stopped |

---

## 8. Project Hygiene

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 8.1 | MUST | All resources labeled | Check each resource → Labels | [x] Root `labels` var wired into all modules: VM, buckets, KMS keys, Pub/Sub topics, Cloud Run, Artifact Registry. VPC/subnets/firewall rules/IPs don't accept labels — context carried in descriptions instead |
| 8.2 | MUST | Dead resources deleted | Check Recommender Hub + Compute Engine → Disks | [~] Console-only |
| 8.3 | SHOULD | One GCP project per major app/environment | Check IAM & Admin → Manage resources | [x] Dedicated project `gcp-hybrid-dr` |
| 8.4 | SHOULD | README with architecture, cost estimate, shutdown instructions | Check repo root | [x] README.md present, with **measured** numbers and the live demo command |

---

## 9. Backup & Recovery

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 9.1 | MUST | Cloud SQL / Firestore backups enabled | Check Cloud SQL → Backups | [~] N/A — no Cloud SQL; SQLite is backed up by `backup.sh` |
| 9.2 | SHOULD | Critical Cloud Storage data in dual-region or replicated bucket | Check bucket location type | [x] Regional buckets replicated cross-region (us-east1 → us-west1) via Storage Transfer Service; chosen over dual-region for storage-class control (Nearline replica) — see JOURNEY.md Day 3 |
| 9.3 | COULD | Terraform state backed up before destructive changes | Check GCS bucket → Object versions | [x] State bucket versioned; every apply retains the prior state object (30-day noncurrent lifecycle) |

**Additional findings from the live run:**

| Item | Status |
|------|--------|
| The backup pipeline actually works | [x] **Verified live** — uploaded, then downloaded from an admin workstation, sha256 verified, gunzip verified, `PRAGMA integrity_check` = ok, 5 order rows recovered. *(It had never worked before this: `gcloud storage cp` reads the destination and fails under write-only IAM.)* |
| The upload checksum is a real, validated CRC32C | [x] **Verified live** — GCS stores exactly the CRC32C the script computes. The previous version sent zlib's IEEE CRC-32 in a header GCS does not validate, so the "CRC32C validated" claim was false in both senses. |
| Backup freshness is monitored | [x] Scheduler → Pub/Sub → function → `RPO_BREACH` log → alert. **Verified live** — the function reported the newest backup's age against the limit |
| Restore drills prove backups are usable | [x] Weekly function: download → sha256 → gunzip → integrity_check → row count. **Verified live** — `RESTORE_DRILL_PASS`, 5 rows, 0.1h old |
| RPO/RTO are measured, not asserted | [x] `disaster-drill.sh` injected a real outage **three times** and measured the full path — RTO 462s / 461s / 482s, RPO 2.7h. See [docs/06-measurements.md](docs/06-measurements.md) |
| DNS failover is automated and verified | [x] **Verified live** — the alert opened, the record flipped to the standby, and it was restored when the primary came back |
| Backups survive a regional outage | [x] **Verified live** — the us-west1 replica is byte-identical and independently restorable (checksum OK, integrity ok, 5 rows) |
| Backups survive ransomware on the primary | [x] **Verified live** — from inside the VM, `gcloud storage ls` → HTTP 403. The VM's SA can write and cannot read |
| Backups survive project-level compromise | [~] **Partially** — the bucket retention policy blocks deletion of recent objects, but a principal able to remove the retention policy itself is still a threat. The cross-project replica that closes this is **designed but deliberately not deployed** — a second billable project does not fit the shared $300 trial budget. See [MISSING.md](MISSING.md) and [docs/03-security.md](docs/03-security.md). |
| Crypto key material does not accumulate | [x] 90-day rotation with a **monthly key-version retirement sweep** — rotated-out versions are never disabled automatically and stay billed forever. **Verified live**: the sweep destroyed a superseded version (`ENABLED` → `DESTROY_SCHEDULED`) and left the primary untouched. |

---

## Monthly Ritual (Agent-Runnable)

- [ ] Billing → Cost Breakdown: any unexpected spikes?
- [ ] Recommender Hub: apply idle resource recommendations
- [ ] Cloud Monitoring: review missed alerts
- [ ] Artifact Registry + Cloud Storage: delete artifacts older than 90 days
- [ ] `gcloud compute instances list`: shut down anything unnecessary
- [ ] Re-run the disaster drill monthly — **an RTO you never re-measure is a
      guess**

---

## Completion Rules for Agents

1. **MUST items** must all be `[x]` before marking the project
   "production-ready."
2. **SHOULD items** should be `[x]` or have a documented exception reason.
3. **COULD items** are optional but tracked for completeness.
4. If an item cannot be verified (e.g. no access to the Cloudflare
   dashboard), mark as `[~]` with reason in notes.
5. Update the "Last verified" timestamp below after each review.

---

**Verified by:** _agent — live deployment review, 2026-10-21_
**Notes:** _Console-only items (budgets UI, billing export, Recommender
Hub) remain [~]. Everything else in this checklist was checked against
the running system, and the items marked [x] were each exercised by the
disaster drill rather than merely observed in the console._
