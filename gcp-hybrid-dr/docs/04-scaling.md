# Scaling: Hybrid Cloud Disaster Recovery

## Current Limits

| Component | Current Scale | Bottleneck |
|-----------|--------------|------------|
| Primary VM | e2-micro (2 vCPU, 1 GB) | CPU-bound; 5 concurrent users max |
| SQLite | Single file, no WAL | No concurrent writers; single connection |
| Backup bucket | 5 GB, Standard | No HA; single region |
| Cloud Run DR | Scale-to-zero | Cold start ~1-2s on failover |
| DNS failover | 300s alert window | Dominates RTO; see below |
| Alert evaluation | Cloud Monitoring | First-party limit, not something to scale |

## Where the RTO Actually Goes

The measured RTO (see [06-measurements.md](06-measurements.md)) is
dominated by one term:

| Stage | Time | Controllable? |
|-------|------|---------------|
| Alert `duration` window | 300s | **Yes** — but shortening it means failing over on a single blip |
| Metric ingest + evaluation | ~60-120s | No — Monitoring's own latency |
| Record flip | ~1-2s | Yes, and already fast |
| TTL expiry | 0-300s | Yes — lower the TTL, at the cost of more DNS queries |
| Cloud Run cold start | ~1-2s | Yes — `min_instance_count = 1` removes it, for ~$5/mo |

**Measured total: 461-482s** across three drills. The 300s alert window is ~65% of it.

The alert window is a *safety* choice, not a performance limit. Halving
it to 150s would halve the RTO and double the false-failover rate.
The honest lever for a production system is a load balancer with its
own health checks, which detects in seconds without the alerting
round-trip at all.

## Scaling Paths

### 10x: 10 concurrent users, hourly backups

- **VM:** e2-micro → e2-medium (2 vCPU, 4 GB)
- **Database:** SQLite → PostgreSQL on Cloud SQL (managed, PITR)
- **Backup:** hourly backups — already a variable change today
  (`backup_cron = "0 * * * *"`), $0 extra on e2-micro
- **RTO:** the alert window becomes the whole story; a 60s window gets
  RTO under 3 min
- **Action needed:** Upgrade VM, migrate to Cloud SQL

### 100x: 100 concurrent users, multi-region primary

- **VM:** e2-medium → MIG (Managed Instance Group) with load balancer
- **Database:** Cloud SQL read replicas for read-heavy workloads
- **Backup:** continuous replication (Cloud SQL read replicas)
- **DR:** Cloud Run min instances = 1 (warm standby, eliminates cold start)
- **Failover:** replace the alert-driven DNS flip with the load
  balancer's own health-checked routing — the alert path exists to work
  *without* a load balancer
- **Action needed:** MIG, Cloud SQL HA, warm standby

### 1000x: Enterprise scale

- **On-prem → Cloud Interconnect** ($1,700/mo)
- **Cloud SQL → Cloud Spanner** (global consistency)
- **Backup:** continuous replication + point-in-time recovery
- **DR:** Full GKE cluster with automated failover
- **RPO:** < 1 minute (continuous replication)
- **RTO:** < 30 seconds (load balancer health check + warm standby)
- **Action needed:** Full re-architecture

## What Changes at Each Scale

| Scale | Primary | Database | Backup | DR | RPO | RTO | Cost |
|-------|---------|----------|--------|-----|-----|-----|------|
| 1x (current) | e2-micro VM | SQLite | Nightly (or hourly) | Cloud Run (zero) | **2.7h measured** | **461-482s measured** | $0.53/mo |
| 10x | e2-medium | Cloud SQL | Hourly | Cloud Run (warm) | 1h | 2min | ~$15/mo |
| 100x | MIG + LB | Cloud SQL + replicas | Continuous | Cloud Run (warm) | 5min | 30s | ~$100/mo |
| 1000x | Interconnect | Cloud Spanner | Continuous | GKE cluster | <1min | <30s | ~$500/mo |

## Decision Record

- **SQLite over PostgreSQL** — chosen for demo simplicity; the DR pattern
  is identical regardless of database engine
- **Nightly backups by default** — chosen for budget; the `backup_cron`
  variable makes hourly a one-line change, and hourly is what the
  measurement run used
- **Nearline for replica** — 30-day minimum matches retention window;
  halves storage cost
- **Write-only backup access** — VM cannot delete existing backups;
  ransomware-proof by design. This constrained the upload mechanism
  (JSON API rather than `gcloud storage cp`) — see
  [03-security.md §4](03-security.md)
- **Online backup API** — no app downtime during backup; same pattern
  as PostgreSQL's pg_basebackup
- **CNAME failover over A-record rewriting** — the target is a name, so
  it never goes stale; Google's Cloud Run front-end IPs rotate, and an
  A record pinned to old IPs is a broken record
- **Alert-driven failover over a routing policy** — health-checked
  Cloud DNS routing policies require an internal load balancer, which
  costs more per month than this entire project's budget
- **No registered domain** — a Cloud DNS zone is authoritative for its
  own name, so failover can be demonstrated and measured without one
- **Custom DNS role** — `roles/dns.resourceRecordsAdmin` does not exist
  and zone-level IAM is unreliable; a project-level custom role with
  only record-set permissions is narrower than `roles/dns.admin` and
  actually works
- **One project, not two** — the cross-project backup replica is the
  strongest answer to project-level compromise, and it was scoped out
  because a second billable project does not fit the $300 trial credit
  shared across the portfolio. The in-project controls that ship
  instead are cheaper and cover the more likely attacker. See
  [MISSING.md](../MISSING.md) for the design and the reasoning.
