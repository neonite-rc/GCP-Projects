# GCP Personal Project Quality & Budget Checklist

> **Verified by:** agent (code review, not live console)
> **Notes:** Items requiring live GCP console access marked [~]. VPN server requires VM by design — public IP and VM-based compute are justified exceptions.

---

## 1. Billing Guardrails

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 1.1 | MUST | Budget alert set at $1, $5, and hard monthly limit with email/phone notification | Check Billing → Budgets & alerts | [~] Console-only — not in Terraform |
| 1.2 | MUST | Billing export to BigQuery enabled | Check Billing → Billing export | [~] Console-only |
| 1.3 | MUST | Free tier e2-micro usage tracked (750 hrs/month in us-east1/us-west1/us-central1) | Check Compute Engine → VM instances → uptime | [x] e2-micro in us-east1 (free-tier eligible) |
| 1.4 | SHOULD | Auto-shutdown scheduled for non-essential VMs/GKE clusters (Cloud Scheduler or Cloud Function) | Check Cloud Scheduler / Cloud Functions logs | [x] `google_compute_resource_policy.auto_shutdown` with `instance_schedule_policy`, toggleable via `enable_auto_shutdown` |
| 1.5 | SHOULD | Recommender Hub reviewed in last 30 days | Check Recommender Hub → Last viewed timestamp | [~] Console-only |

---

## 2. Cost-Conscious Compute

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 2.1 | MUST | Cloud Run or Cloud Functions used as default compute; VMs only when justified | Check Compute Engine vs Cloud Run service list | [x] VM justified — VPN server requires persistent VM for WireGuard |
| 2.2 | MUST | Spot/Preemptible instances used for all non-critical workloads | Check VM instance details → Provisioning model | [~] VM must be always-on for VPN availability |
| 2.3 | MUST | No VM with public IP running 24/7 unnecessarily; Cloud IAP or shutdown policy in place | Check VM external IPs + uptime | [x] Public IP justified — VPN endpoint must be internet-reachable; auto-shutdown available |
| 2.4 | SHOULD | e2-small/e2-medium custom types preferred over n1/n2 unless performance required | Check VM machine type | [x] e2-micro default (smaller than e2-small) |
| 2.5 | SHOULD | GKE Autopilot used for personal K8s projects | Check GKE cluster mode | [~] N/A — no GKE in this project |
| 2.6 | COULD | Cloud Build free tier (120 build-min/day) used instead of self-hosted CI runner | Check Cloud Build history vs Compute Engine CI runners | [~] N/A — no CI/CD in this project |

---

## 3. Storage & Data Lifecycle

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 3.1 | MUST | Cloud Storage lifecycle policy exists: auto-delete temp buckets after 7 days, transition logs to Nearline/Coldline | Check each bucket → Lifecycle rules | [~] N/A — no GCS buckets |
| 3.2 | MUST | BigQuery tables partitioned and clustered; no unpartitioned large tables | Check BigQuery → Table details → Partitioning | [~] N/A — no BigQuery |
| 3.3 | MUST | BigQuery daily spending limit configured | Check BigQuery → Quotas → Daily limit | [~] N/A — no BigQuery |
| 3.4 | SHOULD | Cloud Firestore used instead of Cloud SQL for small apps (within free tier) | Check active database services | [~] N/A — no database needed |
| 3.5 | SHOULD | Old container images cleaned from Artifact Registry | Check Artifact Registry → Image count and age | [~] N/A — no Artifact Registry |

---

## 4. Networking & Egress Control

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 4.1 | MUST | Cross-region egress minimized; storage and compute in same region as users | Check resource regions vs bucket regions | [x] Single region us-east1, routing_mode = REGIONAL |
| 4.2 | MUST | Cloud CDN enabled for static content (within free tier) | Check Cloud CDN → Backends | [~] N/A — no static content to cache |
| 4.3 | SHOULD | Cloud Load Balancer + Cloud Armor in front of public endpoints | Check Load balancing → Frontend IP + Cloud Armor policies | [~] N/A — VPN uses direct IP, not HTTP LB |
| 4.4 | COULD | Cloudflare used in front of GCP for additional caching/DDoS protection | Check DNS records / Cloudflare dashboard | [~] N/A — external service |

---

## 5. Security

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 5.1 | MUST | No service account keys in GitHub repos; Workload Identity Federation used for CI/CD | Check Secret Manager / repo scan / IAM → Service accounts | [x] Dedicated SA with zero scopes/roles; SSH keys via metadata only |
| 5.2 | MUST | Unused APIs disabled | Check APIs & Services → Enabled APIs | [x] Minimal API surface — no APIs enabled via Terraform (only compute needed) |
| 5.3 | MUST | Cloud Storage buckets not publicly accessible unless intentional; uniform bucket-level access enabled | Check each bucket → Permissions → Public access | [~] N/A — no buckets |
| 5.4 | SHOULD | VPC Flow Logs enabled only during debugging, disabled otherwise | Check VPC network → Subnet details → Flow logs | [x] Flow logs enabled at 0.1 sampling on subnet |
| 5.5 | SHOULD | Secret Manager used for API keys and credentials (within free tier: 6 active secrets) | Check Secret Manager → Secret count | [~] N/A — no secrets needed (WireGuard keys managed manually) |

---

## 6. Infrastructure as Code

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 6.1 | SHOULD | Terraform/Pulumi used for resources older than 1 month | Check repo for `.tf` / `.pulumi` files + `terraform state list` | [x] Full Terraform project with modules |
| 6.2 | SHOULD | Terraform state stored in GCS bucket with versioning enabled | Check GCS bucket → state file + Versioning tab | [ ] No GCS backend — local state |
| 6.3 | SHOULD | Provider and module versions pinned (not `latest`) | Check `versions.tf` or `requirements.txt` equivalent | [x] required_version >= 1.5.0, provider ~> 5.0 |
| 6.4 | COULD | `terraform plan` reviewed before every apply | Check CI logs / local shell history | [~] Console-only |

---

## 7. Observability

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 7.1 | MUST | Cloud Monitoring alerts configured for: billing spike, VM CPU >90% (10min), Cloud Run error rate >5% | Check Monitoring → Alerting policies | [~] No monitoring resources in Terraform |
| 7.2 | SHOULD | Log sinks configured with sampling/filtering for noisy logs | Check Logging → Log sinks | [~] No log sinks |
| 7.3 | COULD | Uptime checks (free: 3) on public endpoints | Check Monitoring → Uptime checks | [~] No uptime checks |

---

## 8. Project Hygiene

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 8.1 | MUST | All resources labeled: `env`, `project`, `owner` | Check each resource → Labels | [ ] No labels variable or labels on resources |
| 8.2 | MUST | Dead resources deleted (no idle Cloud SQL, unattached disks, forgotten VMs) | Check Recommender Hub + Compute Engine → Disks | [~] Console-only |
| 8.3 | SHOULD | One GCP project per major app/environment | Check IAM & Admin → Manage resources | [x] Dedicated project |
| 8.4 | SHOULD | README.md exists with architecture, cost estimate, and shutdown instructions | Check repo root for README.md | [x] README.md present |

---

## 9. Backup & Recovery

| # | Priority | Item | Verification Method | Status |
|---|----------|------|---------------------|--------|
| 9.1 | MUST | Cloud SQL / Firestore backups enabled | Check Cloud SQL → Backups / Firestore → Import/Export | [~] N/A — no Cloud SQL |
| 9.2 | SHOULD | Critical Cloud Storage data in dual-region or replicated bucket | Check bucket location type | [~] N/A — no storage |
| 9.3 | COULD | Terraform state backed up before destructive changes | Check GCS bucket → Object versions | [ ] No GCS backend — local state |

---

## Monthly Ritual (Agent-Runnable)

Run these checks monthly and update status above:

- [ ] Billing → Cost Breakdown: any unexpected spikes?
- [ ] Recommender Hub: apply idle resource recommendations
- [ ] Cloud Monitoring: review missed alerts
- [ ] Artifact Registry + Cloud Storage: delete artifacts older than 90 days
- [ ] `gcloud compute instances list`: shut down anything unnecessary

---

## Completion Rules for Agents

1. **MUST items** must all be `[x]` before marking the project "production-ready."
2. **SHOULD items** should be `[x]` or have a documented exception reason.
3. **COULD items** are optional but tracked for completeness.
4. If an item cannot be verified (e.g., no access to Cloudflare dashboard), mark as `[~]` with reason in notes.
5. Update the "Last verified" timestamp below after each review.

---

**Verified by:** _agent name / human name_  
**Notes:** _any exceptions or blockers_
