# Architecture: Hybrid Cloud Disaster Recovery

## Overview

Disaster recovery strategy with a simulated on-prem primary site (e2-micro
VM) backing up to CMEK-encrypted Cloud Storage, replicating cross-region
via Storage Transfer Service, and failing over to a Cloud Run maintenance
page by rewriting a CNAME record.

**Measured on live infrastructure (2026-10-21):** see
[06-measurements.md](06-measurements.md).

## Data Flow

```
PRIMARY SITE (e2-micro VM, us-east1)
  Flask app + nginx + SQLite
  /health endpoint (checks DB, not just web server)
        |
        | cron (02:00 UTC default; hourly in the measured run)
        v
  backup.sh:
    1. SQLite online backup (consistent, non-blocking)
    2. PRAGMA integrity_check (verify BEFORE shipping)
    3. gzip -9 (compress)
    4. sha256sum (checksum manifest)
    5. gcloud storage cp (CRC32C validated upload)
        |
        v
  Cloud Storage: backups (Standard, us-east1)
    - CMEK encryption (Cloud KMS)
    - Versioning enabled
    - 30-day lifecycle + 30-day bucket retention policy
    - Write-only from VM (objectCreator only)
        |
        | Storage Transfer Service (04:00 UTC daily)
        v
  Cloud Storage: backups-replica (Nearline, us-west1)
    - Cross-region replica
    - CMEK encryption
    - Same lifecycle + retention rules

MONITORING:
  Cloud Scheduler (03:00 UTC) -> Pub/Sub -> Cloud Function
    Lists backup bucket, checks newest backup age
    > 24h (or no backups): RPO_BREACH log -> alert -> email

DNS FAILOVER (alert-driven — NO registered domain required):
  Uptime check /health (3 US regions) -> primary_down alert
    Incident OPEN:   dns-failover function -> CNAME -> DR standby
    Incident CLOSED: dns-failover function -> CNAME -> primary target
    TTL: 300 seconds

    The public record is a CNAME whose two targets are HOSTNAMES:
      www.<zone>  CNAME -> primary.<zone>   (A record -> VM's static IP)
                or -> <service>.a.run.app   (the Cloud Run standby)

    A Cloud DNS zone is authoritative for its OWN name, so the zone's
    nameservers answer queries directly:
      dig @ns-cloud-b1.googledomains.com www.<zone>

RESTORE DRILL:
  Cloud Scheduler (weekly, Sun 05:00 UTC) -> Pub/Sub -> Cloud Function
    Downloads newest backup + sha256 manifest, verifies, gunzips,
    integrity_check, row count; RESTORE_DRILL_FAIL log on any failure
```

## Component Responsibilities

| Component | Role | Scaling | Failure Mode |
|-----------|------|---------|-------------|
| Primary VM | Simulated on-prem site | e2-micro (fixed) | VM failure triggers failover |
| Backup bucket | Nightly backup destination | Standard storage | Write fails if bucket full |
| Replica bucket | Cross-region copy | Nearline storage | Replication fails if STS error |
| Cloud Run DR | Maintenance page | Scale-to-zero | Serves 503 page during outage |
| Cloud DNS | CNAME rewritten by the failover function | Global | DNS propagation delay (~5 min TTL) |
| Cloud Function | RPO freshness check + weekly restore drill + DNS failover | Scale-to-zero | Alert on RPO breach / drill failure |
| Cloud KMS | CMEK encryption | Global | Key access denied if not granted |

## Why This Design

1. **VM simulates on-prem** — a real hybrid setup needs Cloud Interconnect
   ($1,700/mo); the VM proves the DR pattern at 0.08% of the cost
2. **Online backup** — SQLite's backup API creates consistent snapshots
   without stopping the app; same pattern as PostgreSQL pg_basebackup
3. **Write-only backup access** — VM can write new backups but cannot list,
   read, or delete existing ones; ransomware on the VM can't destroy recovery
4. **Storage Transfer Service** — server-side replication, no credentials
   on the VM for replication, no egress cost
5. **Nearline for replica** — $0.01/GB vs $0.02/GB; 30-day minimum matches
   retention window exactly
6. **Health check on DB** — `/health` queries the database, not just the
   web server; a dead database should trigger failover
7. **CNAME failover, not A-record rewriting** — the failover target is a
   NAME, so it never goes stale. Google's Cloud Run front-end IPs rotate;
   an A record pinned to last month's IPs is a broken record. Because the
   record *type* never changes there is also no A↔CNAME conflict window
   where the name has no usable record — failover is one atomic change.
8. **No registered domain required** — a Cloud DNS zone is authoritative
   for its own name, so failover can be demonstrated and measured without
   buying a domain. Registration is only needed for real-world public
   resolution.
9. **Standby health probe before flipping** — the failover function
   probes the standby's `/health` before repointing the record. Failing
   over into an unreachable standby is worse than staying on a degraded
   primary, so the function refuses and logs `FAILOVER_ABORTED`.

## Scope: what is deliberately NOT in this design

| Not included | Why | What covers it instead |
|--------------|-----|------------------------|
| **A second GCP project for the backups** | A second billable project does not fit the $300 trial credit shared across the whole 7-project portfolio. It would roughly double the fixed costs for a *control* improvement rather than a *capability* one. | Write-only IAM, a locked bucket retention policy, versioning, continuous cross-region replication, CMEK, and a weekly restore drill — all verified live. A principal who can remove the retention policy itself remains a threat; the cross-project design that closes it is written up in [MISSING.md](../MISSING.md). |
| **A registered domain** | ~$12/yr, and the whole point of a Cloud DNS zone is that it is authoritative for its own name — so failover can be demonstrated and measured without one. | Query the zone's nameservers directly. Registration is only needed for real-world public resolution. |
| **A global load balancer** | A global external Application Load Balancer costs more per month than this entire project. | An alert-driven CNAME rewrite. Slower than a health-checked LB, correct, and $0. |
| **A real database** | Cloud SQL would cost ~$15/mo against a $2 budget, and the DR pattern being demonstrated is engine-agnostic. | SQLite with the online backup API — the same pattern as `pg_basebackup`. |
| **TLS on the primary** | A certificate needs a registered domain. | Documented as the first production step; the standby is TLS-terminated at the Cloud Run front end. |
