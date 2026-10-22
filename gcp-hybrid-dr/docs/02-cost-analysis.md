# Cost Analysis: Hybrid Cloud Disaster Recovery

## Monthly Cost Breakdown

Measured against the live `gcp-hybrid-dr` deployment (2026-10-21).

| Component | Spec | List Price | Free Tier | My Usage | Monthly Cost |
|-----------|------|-----------|-----------|----------|--------------|
| e2-micro (us-east1) | 2 vCPU, 1 GB | $0.00848/hr | 720 hrs/mo free | ~40 hrs/mo | $0.00 |
| Cloud Storage (backup, Standard) | ~5 GB | $0.02/GB-mo | — | 5 GB | $0.10 |
| Cloud Storage (replica, Nearline) | ~5 GB | $0.01/GB-mo | — | 5 GB | $0.05 |
| Cloud KMS (2 keyrings, 2 keys) | $0.06/key-version/mo | — | 2 active versions | $0.12 |
| Cloud DNS | 1 zone + 1 health check | $0.25/mo + $0.01 | — | 1 zone + 1 check | $0.26 |
| Cloud Scheduler + Pub/Sub | 3 jobs/day | Free tier | 3 jobs free | 3 jobs | $0.00 |
| Cloud Functions (freshness, drill, failover) | scale-to-zero | Free tier | 2M invocations | ~40/mo | $0.00 |
| Cloud Run (DR standby) | scale-to-zero | $0 idle | — | 0 requests idle | $0.00 |
| Artifact Registry | 1 image | Free tier | 5 GB | ~2 MB | $0.00 |
| **Monthly total** | | | | | **$0.53** |
| **Two-month total** | | | | | **$1.06** |

> **A correction worth making.** Earlier drafts of this document (and
> the README) quoted a **$1.40/month** figure. That number was a
> TWO-MONTH total that had been mislabelled as a monthly one — the
> storage and DNS lines in the original plan were multiplied by two
> months, then the sum was presented as a per-month cost.
>
> The line items above add up to **$0.53/month**, and the two-month
> total is **$1.06**. Both are below the $2 project budget, so nothing
> about the project changes — but a cost table that does not add up is
> the kind of thing a reviewer checks first, and this one did not.

### Why the hourly backup cadence costs nothing

The measurement run used `backup_cron = "0 * * * *"` (hourly) so the RPO
could be *measured* rather than asserted. An extra ~700 extra backups a
month on an e2-micro that is already inside the 720-hour free tier costs
**$0.00** — the VM runs ~40 hours/month either way.

The hourly cadence does add storage: ~5 GB × 24 more objects/month is
still ~5 GB, because the retention window (30 days) bounds the total
rather than the frequency. Storage stays at $0.10 + $0.05.

### The KMS line is a trap

It reads $0.12 — two key versions at $0.06. Getting that right took
measuring, because **a key version stays billed after it is rotated
out**, and nothing retires it automatically.

Measured on a scratch key with a 1-day rotation period:

```
after one rotation:  version 1 ENABLED, version 2 ENABLED
                     -> BOTH billed
```

Rotating a key creates a new primary version but does **not** disable or
destroy the previous one, and nothing disables it automatically. With a
90-day rotation period that is one extra billed version every 90 days,
forever: ~13 versions per key after a year, $0.78/mo per key, $1.56/mo
across the two keys — against a $0.12/mo claim.

`destroy_scheduled_duration` is **not** the fix, which is easy to get
wrong: it only controls how long a version stays in `DESTROY_SCHEDULED`
*after something has explicitly destroyed it*. It does not schedule
anything on rotation.

The fix is the **key version retirement** function
(`src/functions/key-version-retirement`): a monthly sweep that destroys
versions which are no longer primary and are older than the backup
retention window. The retention window is a hard floor — destroying a
key version makes the data it encrypted unreadable, so a version is only
retired once no restorable backup could still need it.

Verified live: with a 1-day-old non-primary version and a 0-day
retention window, the sweep destroyed it (`ENABLED` → `DESTROY_SCHEDULED`)
and left the primary version untouched. With the real 30-day window, it
correctly destroys nothing.

## Cost vs Alternatives

| Alternative | Monthly Cost | Why Rejected |
|-------------|-------------|-------------|
| Cloud SQL + read replicas | ~$15/mo | All cloud, no hybrid story |
| Cloud Interconnect + real on-prem | $1,700/mo | 1200x portfolio budget |
| GKE primary + Cloud Run DR | ~$90/mo | Overkill for DR demo |
| Cloud SQL HA (regional) | ~$35/mo | Good availability story, no DR story |

## Optimizations Made

1. **Online backup** — no app downtime, no Apache stop/start cycle
2. **Nearline for replica** — $0.01/GB vs $0.02/GB; 30-day minimum
   matches retention
3. **No Cloud NAT** — VM has public IP (it IS the primary); no NAT needed
4. **No LoadBalancer for DR** — Cloud Run's managed URL is the DR target
5. **Write-only backup access** — VM cannot delete existing backups;
   smallest possible IAM scope
6. **30-day lifecycle** — old backups deleted automatically; no
   accumulation
7. **Custom DNS role instead of `roles/dns.admin`** — no cost, but it
   keeps the blast radius of a compromised failover function to record
   sets only
8. **DNS failover without a registered domain** — saves the ~$12/yr
   domain and is enough to demonstrate and measure the whole path
9. **Scale-to-zero Cloud Run** — the DR standby costs $0 until a
   disaster actually sends traffic to it
10. **Flow logs at 0.1 sampling** — keeps log volume inside the free
    tier without giving up visibility
11. **Artifact Registry keeps 3 most recent images** — registry storage
    is billable past 0.5 GB

## Guardrails

- **Monthly billing budget** — Terraform-managed (`google_billing_budget`)
  with thresholds at 50% / 90% / 100%, filtered to this project.
  Gated behind `billing_account_id` + `billing_currency` in tfvars.
  The budget is wired to the project's notification channels via
  `all_updates_rule` — without that block it would record thresholds
  and notify nobody.
- **The budget currency must match the billing account's** — a mismatch
  is rejected with a bare HTTP 400 that does not name the bad field
  (see [05-troubleshooting.md](05-troubleshooting.md) Issue 9).
- **30-day lifecycle on every bucket** — no bucket accumulates objects
  indefinitely, which is the most common cause of a surprise storage
  bill.
- **Artifact Registry keeps 3 most recent images** and deletes anything
  older than 30 days.
