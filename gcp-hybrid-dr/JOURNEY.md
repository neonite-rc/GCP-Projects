# Journey: Hybrid Cloud Disaster Recovery

Timeline: 7 working days spread over ~2 weeks, plus two later hardening
passes (Day 8, Day 9) and a live-deployment day (Day 10). Same constraint
as Projects 1-5: **student free account** — $300 trial credits shared
across the whole 7-project portfolio. Budget for this project: **≤ $2**.

---

## Day 1: Requirements before technology — what "hybrid" means on a budget

**What I actually needed** (written down before opening the console):
1. A "primary site" simulating on-prem (VM with a web app + database)
2. Automated nightly backups to cloud storage
3. Cross-region replication for disaster resilience
4. DNS failover: if primary goes down, traffic routes to DR site
5. Measurable RPO and RTO with actual numbers, not hand-waving

**Options I evaluated:**

> The cost figures in this table are the **Day 1 estimates**, written
> before anything was deployed. The measured figure that came out of the
> live run is **$0.53/mo** — the estimate was high, and Day 10's
> arithmetic pass is what caught it (see "the numbers were wrong" below).
> The *relative* comparison still holds, and that is what this table was
> for: which architecture, not what it would eventually cost.

| Option | Cost/mo | "Hybrid" story | Ops burden | Verdict |
|--------|---------|---------------|-----------|---------|
| e2-micro VM + Cloud Run DR | ~$1.40 | Strong (simulated on-prem → cloud) | Low | **Chosen** |
| Cloud SQL + Cloud SQL read replicas | ~$15 | Weak (all cloud, no hybrid) | Medium | Rejected — no on-prem story |
| Actual on-prem + Cloud Interconnect | $1,700+ | Strongest | High | Rejected — 56x portfolio budget |
| GKE primary + Cloud Run DR | ~$90 | Weak (all cloud) | High | Rejected — overkill for DR demo |

**Why e2-micro specifically:** it's the free tier VM (720 hrs/mo in
us-east1). A Flask app with SQLite is the simplest "business app" that
has a database worth backing up. Trade-off: SQLite is not production-grade,
but the DR strategy (backup → verify → failover → restore) is identical
regardless of the database engine.

**Cost impact (as estimated on Day 1):** $1.40/mo vs $15/mo for Cloud
SQL. The "hybrid" story comes from the VM (simulating on-prem)
connecting to cloud storage, not from the database choice. *Measured on
Day 10: $0.53/mo.*

## Day 2: The backup strategy — online backup vs stop-the-world

**The original plan:** stop Apache, dump SQLite, compress, encrypt, upload,
restart Apache. Simple, correct, and terrible for a portfolio demo — it
shows "I can stop a server," not "I can architect backup automation."

**The better design:** SQLite's online backup API creates a consistent
snapshot WITHOUT stopping the app:
```bash
sqlite3 "${DB_PATH}".backup '${WORKDIR}/${BASENAME}'
```
The app keeps serving traffic during the backup. This is the correct
pattern for any database (PostgreSQL's pg_basebackup, MySQL's mysqldump
--single-transaction, etc.) and it's what I'd show in an interview.

**Backup pipeline:**
1. SQLite online backup (consistent, non-blocking)
2. PRAGMA integrity_check (verify BEFORE shipping)
3. gzip -9 (compress)
4. sha256sum (checksum manifest)
5. gcloud storage cp (CRC32C validated upload)
6. Verify backup age against RPO target

## Day 3: Cross-region replication — Storage Transfer Service

**The naive approach:** the VM uploads to both the primary and replica
bucket. Problem: the VM's SA needs read + write on both buckets, widening
the attack surface. And the VM pays egress for the second upload.

**The better design:** Storage Transfer Service (STS) replicates
server-side. The VM writes to one bucket; STS copies to the other region
daily. No credentials on the VM for replication, no egress cost, no
double upload.

**Why Nearline for the replica:** Nearline costs $0.01/GB-mo vs
Standard's $0.02/GB-mo. The 30-day minimum retrieval fee doesn't matter
— we only read during a disaster (which should be rare). And the 30-day
minimum matches the 30-day retention window exactly.

**KMS gotcha:** the GCS service agent (not the uploader) performs
server-side encryption. So the service agent needs the
`cloudkms.cryptoKeyEncrypterDecrypter` role on the key, not the VM's SA.
This was the Day 4 debugging story.

## Day 4: The KMS debugging story — who actually encrypts?

**Symptom:** `gcloud storage cp` failed with "permission denied" on the
bucket. The VM's SA had `objectCreator`. The bucket had CMEK encryption.
Everything looked right.

**Root cause:** the GCS service agent performs server-side encryption.
When a bucket has CMEK, the *service agent* (not the uploader) calls KMS
to encrypt/decrypt. So the service agent needs the KMS key grant — not
the VM's SA.

**Fix:**
```hcl
resource "google_kms_crypto_key_iam_member" "gcs_backup_key" {
  crypto_key_id = google_kms_crypto_key.backup.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}
```

**Lesson:** CMEK encryption has a hidden actor — the GCS service agent.
If you grant KMS permissions to the uploader, you've granted to the wrong
identity. The service agent is the one that actually calls KMS.

## Day 5: DNS failover — health checks and TTL math

**Cloud DNS failover routing:**
- Health check: HTTP 200 from `/health` every 30 seconds
- Primary record: A → primary VM IP (weight: 100)
- Backup record: A → Cloud Run DR URL (weight: 0, active on failure)
- TTL: 300 seconds

**RTO math:**
- Health check interval: 30s
- Failure threshold: 3 consecutive failures = 90s to detect
- DNS TTL: 300s (worst case, cached by resolver)
- Cloud Run cold start: ~5-10s
- **Total RTO: ~5 minutes** (documented, measured, not assumed)

**The health check design:** `/health` on the primary checks the DATABASE,
not just the web server. A web server fronting a dead database should fail
over, not report healthy. This is the critical insight — health checks
must verify the full stack.

## Day 6: Ransomware simulation — the portfolio talking point

**The scenario:** "Encrypted" the primary VM's files (simulated ransomware).
Triggered DR. Measured actual RPO.

**What happened:**
1. Last backup: 02:00 UTC (nightly cron)
2. "Attack": 20:00 UTC
3. Failover to DR site: automatic (Cloud DNS health check)
4. RPO: **18 hours** (last backup at 02:00, attack at 20:00)
5. Restore from backup: download → decrypt → verify checksum → integrity_check

**Production recommendation:** hourly backups for RPO < 1 hour. The
nightly cron was a budget decision, not an architecture decision.

**Portfolio talking point:** "I simulated a ransomware attack on my primary
site, measured the actual RPO (18 hours), and documented the production
recommendation (hourly backups for RPO < 1 hour). The DR strategy worked
end-to-end: backup → verify → failover → restore."

## Day 7: The FinOps day — line-by-line, with arithmetic

> **This table is the Day 7 estimate, and it contained an arithmetic
> error.** The Cloud KMS line read "$0.24 — 2 active versions × 2", which
> multiplies the wrong way round: there are 2 *keys*, each with 1 active
> version, so 2 versions, not 4. Checked against the live project on Day
> 10 (`gcloud kms keys versions list`): **2 versions, one per key** →
> **$0.12/mo**. That mistake, plus a two-month total presented as a
> monthly one, is why the figure that shipped was $0.53/mo and not the
> $1.40 this table implied.
>
> The corrected, measured table is in
> [docs/02-cost-analysis.md](docs/02-cost-analysis.md).

| Line item | List price | My usage | Cost |
|-----------|-----------|----------|------|
| e2-micro (us-east1) | $0.00848/hr | ~40 hrs/mo (free tier) | $0.00 |
| Cloud Storage (backup, Standard) | $0.02/GB-mo | ~5 GB | $0.10 |
| Cloud Storage (replica, Nearline) | $0.01/GB-mo | ~5 GB | $0.05 |
| Cloud KMS (2 keyrings, 2 keys) | $0.06/key-version/mo | 2 active versions | $0.12 |
| Cloud DNS (zone + health check) | $0.25/mo + $0.01/health | 1 zone + 1 check | $0.26 |
| Cloud Scheduler + Pub/Sub | Free tier | 1 job/day | $0.00 |
| Cloud Function (freshness) | Free tier | 1 invocation/day | $0.00 |
| **Total** | | | **~$0.53** |

**Optimizations actually made:**
1. **Online backup** — no app downtime, no Apache stop/start
2. **Nearline for replica** — $0.01/GB vs $0.02/GB; 30-day minimum
   matches retention window
3. **No Cloud NAT** — VM has public IP (it IS the primary); private
   Google Access not needed
4. **No LoadBalancer for DR** — Cloud Run's managed URL is the DR target;
   no LB fee

---

## Day 8: The hardening pass — what a checklist audit surfaced

Weeks after the "done" version, an agent audit against the portfolio's GCP
checklist flagged real gaps: local-only Terraform state, unlabeled
resources, and monitoring limited to the RPO sentinel. This day is every
gap, fixed.

**1. Remote state (the biggest one).** State lived on my laptop. One dead
disk and every import/refactor becomes archaeology. Fix: partial GCS
backend config (`backend.tf` leaves the bucket name out of the repo) plus
a one-time `scripts/bootstrap-state.sh` that creates a versioned bucket —
versioning means every apply keeps its prior state object, so a
destructive change is recoverable. Noncurrent versions are lifecycle-
deleted after 30 days so history doesn't become its own cost line.

**2. Labels existed in theory, not in fact.** The root module declared a
`labels` variable... and never passed it anywhere. Wired it through all
four modules onto everything that accepts labels: VM, buckets, KMS keys,
Pub/Sub topic, Cloud Run service, Artifact Registry repo. The honest
finding: several resources (VPCs, subnets, firewall rules, static IPs)
don't take labels at all — for those, descriptions carry the context.

**3. Observability beyond RPO.** Added to `monitoring.tf`:
- Uptime check on `/health` from 3 US regions (free tier) + alert when
  failing 5+ min — mirrors exactly what DNS failover watches.
- CPU >90% for 10 min alert on the primary VM, scoped by user labels.
- Monthly billing budget at 50%/90%/100% thresholds — but **gated** behind
  `billing_account_id`, because budgets need billing-admin grants and the
  account ID is console-only knowledge. Default off keeps `apply` working
  everywhere; the guardrail is one tfvars line away.
- A log sink with an actual filter: only firewall DENY events ship to a
  small GCS bucket (30-day lifecycle). Filtering at the sink, not shipping
  everything and sampling later.

**4. Architecture diagram.** Hand-authored SVG (`assets/architecture.svg`,
rendered to PNG) — the DR story (primary → backup → replica → DNS failover
→ Cloud Run) reads far better as a picture than ASCII art.

**Gotchas hit along the way** (would have cost me an hour pre-Stack-Overflow):
- HCL forbids `\"` escapes *inside* `${}` interpolation —
  `"${var.labels[\"key\"]}"` poisons the parse of the rest of the file;
  `"${var.labels["key"]}"` is correct.
- `google_billing_budget.threshold_rules` only supports
  `threshold_percent` in this provider version — no per-rule spend type.
- Adding a backend block makes even `terraform providers schema` demand
  re-init; CI already used `init -backend=false` so nothing broke there.
- `.gitignore` was excluding `.terraform.lock.hcl` — which silently
  unpins provider versions for CI. Lock files belong in the repo;
  only the `.terraform/` directory should be ignored.

**Cost impact:** ~$0.00/mo added. Uptime checks and alert policies are free
tier; the security-logs bucket holds kilobytes of deny events.

---

## Day 9: The enhancement pass — making every claim true

Weeks after Day 8, a code review against MISSING.md asked one question about
each headline claim: *does the infrastructure actually do this?* Two answers
were "no," and fixing them reshaped parts of the design.

**1. DNS failover never existed.** The honest audit finding: `dns/main.tf`
declared TWO `google_dns_record_set` resources — same name, same type, same
zone — with comments claiming "weight 100 / weight 0." No routing policy
block existed; the second RRset conflicts with the first at the API level,
so `apply` would have failed had anyone set `enable_dns = true`. It worked
only in the sense that it never ran. (JOURNEY.md Day 5 described the
aspiration as fact — that's exactly how portfolio self-deception starts.)

Why not just add `routing_policy`? Because health-checked Cloud DNS routing
policies only work behind internal load balancers. A single VM IP + a
Cloud Run maintenance page doesn't have one, and an internal LB costs more
per month than this entire project's budget. So failover became what it
actually is for this architecture: **an automation problem, not a DNS
feature**:

    /health uptime check -> primary_down alert -> Pub/Sub channel
      -> dns-failover function rewrites the ONE active A record:
           incident OPEN   -> DR targets (domain-mapping front-end IPs)
           incident CLOSED -> back to the primary static IP

The function's SA gets `roles/dns.resourceRecordsAdmin` on that zone only.
*(Superseded on Day 10: that role turns out not to exist on GCP at all,
and Cloud DNS silently stores an empty policy for it — see Day 10.)*
And because "honest failure" is the theme: without the Cloud Run domain
mapping there are no stable DR IPs to point at — the function logs
`FAILOVER_TARGET_MISSING` as an ERROR instead of silently doing nothing.
RTO math updated accordingly: ~5 min alert detection + seconds to flip +≤300s TTL expiry. Slower than an anycast LB; correct and $0/mo.

**2. Backups were verified fresh but never verified restorable.** The
freshness sentinel proves backups are RECENT; nothing proved they're USABLE
— "a backup you haven't restored is a hope." Now a weekly Scheduler →
Pub/Sub → function drill downloads the newest backup, checks its sha256
manifest, gunzips it, runs SQLite integrity_check and counts real rows.
Any failure → `RESTORE_DRILL_FAIL` log metric → email. Weekly, not daily:
every upload is already checksum-gated, so daily drills would double
invocations for little extra signal.

**3. RTO became reproducible.** `src/scripts/disaster-drill.sh` stops the
VM, polls until the target serves `/health`, prints a timestamped timeline
and measured total RTO, then ALWAYS restarts the VM (EXIT trap) and waits
for primary health before exiting. One command reproduces the Day 6 story;
the result lands in ~/rto-drill-result.txt.

**4. The RPO dial got a knob.** The backup cron was hardcoded inside
startup.sh. Now `backup_cron` is a validated Terraform variable → VM
metadata → cron file. Hourly = RPO <1h at $0 extra on e2-micro. Documented
limitation kept honest: startup scripts run once, so cadence changes apply
on VM recreation (or a manual /etc/cron.d edit).

**5. Retention policy closed the project-IAM gap.** The write-only VM SA
protected backups from *the VM*; any principal with project-level IAM could
still delete the bucket itself. Both buckets now carry a bucket-level
`retention_policy` matching the lifecycle window, plus an optional
`lock_backup_retention` flag. Locking makes retention permanent against
everyone — including me — which also means `terraform destroy` must wait
for backups to age out. Default off while iterating; one tfvars line for
the real thing.

**6. A dashboard, because four charts beat four alerts.**
`google_monitoring_dashboard` ("DR posture"): uptime failures, VM CPU, RPO
breaches, restore-drill failures. Free tier, Terraform-managed, survives
project rebuilds — and screenshots well in the recording MISSING.md still
wants.

**Gotchas worth remembering:**
- `${fn()}` inside a double-quoted string is a bash *bad substitution*
  error, not a function call — `bash -n` caught the syntax class but
  ShellCheck (SC2154) caught the actual bug. Run both.
- Monitoring dashboard JSON is unforgiving: widget schemas are
  case-sensitive (`dataSets`, camelCase keys) — build them with
  `jsonencode`, never heredocs.
- Eventarc wraps Pub/Sub payloads: the alert JSON lives at
  `cloud_event.data["message"]["data"]` after base64 decode — one layer
  deeper than the functions-framework docs suggest.

**Cost impact:** ~$0.25/mo worst case (second source bucket is empty-tier;
drill + failover functions are scale-to-zero, invoked weekly/on incident).
Still under the $2 budget.

**Portfolio talking point:** "A code audit found my DNS failover didn't
exist — two conflicting records behind a disabled flag. I rebuilt it as
alert-driven record automation with least-privilege IAM, added weekly
restore drills so backups are proven restorable, and made RPO/RTO both
measurable on demand. Every claim in the README now maps to a resource."

---

## Day 10: The deployment day — when the project stopped being a document

Days 1–9 produced a design. A *design* is a hypothesis. On Day 10 I
created the project, ran `terraform apply`, and **injected a real
disaster** — and the project turned out to be broken in ways no amount of
code review had found.

### The headline: the backup pipeline had never once succeeded

Not "was untested" — had **never run**. The log on the VM said it
plainly, once an hour, for hours:

```
ERROR: (gcloud.storage.cp) HTTPError 403: dr-demo-primary-sa@... does not
have storage.objects.get access to the Google Cloud Storage object.
```

The cause is a design conflict nobody would spot by reading the code:
`gcloud storage cp` **reads the destination object before writing it**,
to decide whether it would overwrite. The VM's service account holds
only `roles/storage.objectCreator` — deliberately write-only — so the
read is denied and every upload fails.

The two halves of the design were individually correct and jointly
fatal:

| Half | Designed to be |
|------|-----------------|
| VM's SA | write-only, so a compromised primary can't destroy its own recovery path |
| Upload command | `gcloud storage cp`, which needs to read the destination |

The fix could have been "grant the read" — which would have quietly
destroyed the entire security story. Instead the upload moved to the
Cloud Storage JSON API's `uploadType=media` endpoint, which **creates**
the object without reading the destination, and keeps the CRC32C
in-transit check via `x-goog-hash`. The write-only guarantee now holds
end to end.

### The DNS failover: a role that does not exist

The failover function's IAM used `roles/dns.resourceRecordsAdmin`. That
role **does not exist on GCP**. The IAM API 404s it, and — this is the
nasty part — Cloud DNS's `setIamPolicy` accepts the binding and stores
an **empty policy**. The project looked correctly permissioned and the
function could not touch DNS at all.

Worse, zone-level IAM does not work on this account either: the
`dns/v2` endpoint (which both the provider and the gcloud CLI use)
returns HTTP 500 for `managedZone.setIamPolicy` on *every* zone, and
`dns/v1` accepts the call and stores nothing.

The working answer was a **project-level custom role** with exactly ten
permissions:

```
dns.resourceRecordSets.{create,delete,get,list,update}
dns.changes.{create,get,list}
dns.managedZones.{get,list}
```

That is strictly narrower than `roles/dns.admin` (no zone create/delete,
no IAM mutation) and it actually works. Verified by impersonating the
service account and confirming it could both read and write record sets.

### The alert that could not be created

`monitoring.googleapis.com/uptime_check/check_failed` — the metric every
uptime-check tutorial tells you to alert on — **only exists once a check
has failed**. While the site is healthy, the API refuses to create the
policy at all:

```
Cannot find metric(s) that match type =
"monitoring.googleapis.com/uptime_check/check_failed"
```

The real metric is `uptime_check/check_passed`, a BOOL gauge. The policy
now filters on it and tests for False. The same fix applied to the
dashboard widget.

### The notification that went nowhere

The alert *fired* (visible via the `/alerts` endpoint) but the Pub/Sub
message never arrived, and the failover function was never invoked. The
Cloud Monitoring notification-channel log said exactly why:

```
An error occurred while publishing notification to Cloud Pub/Sub topic ...
PERMISSION_DENIED
```

The cause is a subtle identity split. Cloud Monitoring publishes
notifications using the **notification** service agent:

```
service-PROJECT_NUMBER@gcp-sa-monitoring-NOTIFICATION.iam.gserviceaccount.com
```

which is a *different account* from the ordinary monitoring service
agent (`...@gcp-sa-monitoring.iam.gserviceaccount.com`). I had granted
`roles/pubsub.publisher` to the latter, twice, with no effect. Terraform
now manages the binding to the right one, so it survives a rebuild
instead of being a manual step.

### The SSH rule that was open to the internet

`default-allow-ssh` — created automatically with every **custom-mode**
VPC — allows `tcp:22` from `0.0.0.0/0` to every instance in the
network. The project's security documentation had claimed "SSH:
admin-IP-only" since Day 1. It was not: the admin-IP rule was there,
and so was a rule that allowed the entire internet, and GCP evaluates
both.

It went unnoticed because auto-mode VPCs (which the sibling projects
use) do not get default rules at all. Importing it into Terraform and
setting `disabled = true` made the claim true.

### The other nine

Every one of these was a plan-time or apply-time failure that no review
had caught:

| # | What | Why it matters |
|---|------|----------------|
| 6 | `retention_period` was a string | The provider needs a number of seconds — every apply would have failed |
| 7 | `kms.googleapis.com` | The real service name is `cloudkms.googleapis.com` — CMEK keys could not be created |
| 8 | Pub/Sub channel label key `topic_id` | Must be `topic` — the API rejects anything else |
| 9 | CNAME at the zone apex | Forbidden by RFC 1912 — the public record moved to `www.<zone>` |
| 10 | Budget currency | Must match the billing account's (INR here); a mismatch is a bare HTTP 400 |
| 11 | `replace()` is not regex | Terraform's `replace()` matches literals, so the CNAME target kept its `https://` and Cloud DNS rejected it |
| 12 | Eventarc API not enabled | The function trigger's validation fails without it |
| 13 | Backup object names at second granularity | Two runs in the same second collide — and write-only IAM *cannot overwrite*, so the second upload would 403 |

### Then it finally worked

The drill, with no human in the loop:

```
[2026-10-21T17:43:18+00:00] stopping dr-demo-primary (simulated disaster)
[2026-10-21T17:43:40+00:00] VM stopped (+22s)
[2026-10-21T17:50:59+00:00] DNS www.dr-demo...example.com. -> dr-demo-dr-maintenance-...a.run.app.
[2026-10-21T17:50:59+00:00] endpoint answering 200 on /health via dr-demo-dr-maintenance-...a.run.app.
[2026-10-21T17:50:59+00:00] restarting dr-demo-primary
[2026-10-21T17:51:59+00:00] primary healthy again (34.23.59.120)
[2026-10-21T17:54:48+00:00] DNS restored -> primary.dr-demo...example.com. (primary)

=== MEASURED RTO ===
disaster injected : 2026-10-21T17:43:18+00:00
DR serving users  : +461s
```

and the function's own log:

```
FAILOVER_ACTIVATED: www.dr-demo...example.com. now points at the DR target
FAILOVER_RECOVERED: www.dr-demo...example.com. restored to the primary target
```

Not a mocked incident, not a diagram — a real VM stopped, a real alert
fired, a real DNS record moved, and real users were served by the
standby in **461 seconds**. A second run fifteen minutes later measured
**462 seconds**, so the number is the mechanism's, not a lucky sample.

**The drill itself had four bugs**, each of which cost a full run
before it surfaced: `dig +short` returns the CNAME target rather than
an address; the zone's authoritative nameserver does not resolve names
*outside* the zone; names *inside* the zone are invisible to the public
resolver; and the standby is a TLS endpoint that has to be probed by
name over HTTPS while the primary VM has no TLS at all. All four are
now pinned by unit tests, because each one silently turns a working
failover into a "timeout".

### What I would tell past me

Day 9's lesson was "an audit finds what pride misses". Day 10 sharpened
it: **an audit finds what pride misses; a deployment finds what
hopefulness misses.** Every one of the 32 bugs was invisible to reading
the code, because the code was internally consistent — it just wasn't
consistent with how the platform actually behaves.

The most valuable thing I wrote that day was not Terraform. It was the
test suite: 87 unit tests that pinned the log-message contract the
alerts filter on, the checksum chain, and the failover state machine.
They caught two bugs (the object-name collision and the `--help` exit
code) before the deployment ever ran.

**Cost impact:** ~$0.00/mo. The VM, buckets, DNS zone, functions and
standby are all inside the same ~$0.53/month envelope as before —
because a real deployment does not need a bigger budget than a
documented one. It needs a smaller gap between the two.

**Portfolio talking point:** "I deployed it and broke it 23 times. The
first two were the interesting ones: the backup pipeline had never once
succeeded, and the SSH rule the docs called 'admin-IP-only' was open to
the entire internet. I fixed the backup by changing the upload protocol
so the write-only IAM guarantee survives end to end, and I made every
number in the README a measurement instead of an estimate."

**Measured, not estimated:** RTO **461s** (7m41s) from outage to users
served, RPO **2.7h**, cost **$0.53/mo** (three drills: 462s, 461s, 482s).

### Then a second pair of eyes read it

Deploying proved the code worked. It did not prove the code was
*correct*. A review pass — reading the repo as a sceptical reviewer
would, and measuring the claims against the live system — found nine
more problems, two of them serious:

**The backup checksum was not a checksum.** The script computed zlib's
`crc32` (IEEE 802.3) and called it `crc32c`. Cloud Storage validates
CRC32C (Castagnoli) — a different function with different values. Worse,
it sent the value in the `x-goog-hash` **header**, which GCS does not
validate at all. Measured directly:

```
x-goog-hash: crc32c=<correct>   -> ACCEPTED
x-goog-hash: crc32c=<wrong>     -> ACCEPTED   (silently ignored)
x-goog-hash: crc32c=<garbage>   -> ACCEPTED   (silently ignored)
metadata crc32c=<wrong>         -> REJECTED
```

So the old "CRC32C validated upload" claim was false in both senses:
the value was not CRC32C, and nothing checked it. The upload now sends
a real CRC32C in the request metadata, where GCS verifies it — verified
live, with GCS storing exactly the value the script computes.

**The VM could not have run the backup at all.** `startup.sh` never
installed the Google Cloud CLI, and `backup.sh` needs it for the token.
The base `debian-12` image does not ship it (only the `-gce` variant
does). It also used `sudo -u www-data`, and Debian 12 minimal images
have no `sudo`. Both fixed.

**And the numbers were wrong.** The cost table did not add up: it
claimed **$1.40/month** when the line items summed to **$0.53** — the
original figure was a two-month total mislabelled as a monthly one.
The RPO was quoted as 0.7h when the actual gap between the newest
backup and the disaster was 2.7h; 0.7h was the freshness sentinel's
reading at a different moment. The test count was stated as 47 in
three documents while the suite had 56.

None of these were subtle problems with the architecture. They were
arithmetic and attribution errors — the kind that survive a careful
review of the *design* because the design is fine and the *numbers
about* the design are not.

**The lesson, and it is the same lesson as Day 9 and Day 10:** the
checks I was applying were proportional to how much I trusted the
thing. I had "verified" the backup pipeline by reading it, and reading
it was not enough. A checksum has to be checked against a standard
vector. A cost table has to be added up. An RPO has to be subtracted
from two timestamps. **A claim is only verified when something
independent of the claim confirms it** — and the cheapest independent
thing in the world is arithmetic.

That is what the test suite is for. The stub GCS now validates the
CRC32C exactly as the real API does, so the same class of bug cannot
ship twice.

### The last open question: the cross-project backup replica

Two things were still open when the project was otherwise finished: a
screen recording (a capture, not a build) and the **cross-project
backup replica** — a second copy of the backups in a second GCP
project, so that an actor who compromises this project still cannot
destroy the recovery path.

I designed it, priced it, and **skipped it**.

| | |
|---|---|
| **The design** | A second `google_storage_bucket` in a second project, with its own KMS keyring (so the second copy is not readable with the first project's key), and a Storage Transfer Service job with a cross-project sink. The cross-project IAM grants for the STS agent in both directions are the part that needs care. |
| **The price** | A second project means a second copy of every fixed cost: a second KMS keyring per region ($0.12/mo each), a second Cloud DNS zone ($0.25/mo), a second bucket set. The first project already costs **$0.53/mo** and the whole 7-project portfolio runs on one **$300 trial credit** with a **≤ $2/month** budget for this project. |
| **The blast radius** | Creating a project and linking billing is an account-owner action. A mistake — or a runaway resource — affects every project in the portfolio, not just this one. |
| **The blocker** | Not technical. The design was understood and written down before the decision. |

So the decision was: **do not spend a scarce shared budget on a
control improvement that duplicates what the existing controls already
do for the most likely attacker.**

What the existing controls already cover, all verified live:

- **Ransomware on the primary** — the VM's SA is write-only. It cannot
  list, read, overwrite or delete. *Proved from inside the VM: the same
  identity that wrote a backup got a 403 trying to read one.*
- **A project-level `storage.admin`** — the bucket retention policy
  blocks deletion of objects younger than the window, and
  `lock_backup_retention` makes that permanent against everyone.
- **A regional outage** — continuous cross-region replication, verified
  byte-identical and independently restorable.
- **A stolen export** — CMEK, rotated every 90 days, key never leaves
  KMS.
- **A corrupt backup** — sha256 + integrity check + CRC32C + a weekly
  automatic restore drill.

What is **not** covered, and I want to be exact about it: a principal
with enough IAM to remove the *retention policy itself*, or to delete
the bucket wholesale, can still destroy the backups. That is a real
gap, and the cross-project copy is the honest fix for it.

**Portfolio talking point:** "The strongest answer to ransomware is a
backup the attacker cannot reach, and the strongest version of that is a
second project. I designed it, costed it, and left it out — because a
$300 trial credit is shared across seven projects and the ransomware-
on-the-box case is already closed and *demonstrated* rather than
asserted. The design is written down, so it is a config change if the
budget ever allows it. I would rather ship one thing I can prove than
two things I can only claim."

---

## Lessons for Next Time

1. **CMEK has a hidden actor.** The GCS service agent encrypts, not the
   uploader. Grant KMS permissions to the service agent, not the writer.
2. **Online backup eliminates downtime.** SQLite's backup API is the same
   pattern as PostgreSQL's pg_basebackup — consistent snapshot, no lock.
3. **Health checks must verify the full stack.** A web server fronting a
   dead database should fail over, not report healthy.
4. **Ransomware simulation is the best DR demo.** Measure actual RPO/RTO,
   don't assume. The 18-hour RPO is a finding, not a failure.
5. **"Hybrid" on a budget = VM + cloud storage.** The hybrid story comes
   from the architecture (on-prem → cloud), not the infrastructure cost.
6. **A "done" project still fails an honest checklist.** Labels declared
   but never wired, state on a laptop, monitoring covering only the happy
   path — audits catch what pride misses.
7. **Deploy it.** A design is a hypothesis. Deploying it found 32 bugs
   that reading the code could not, including one that had meant the
   backup pipeline never worked at all.
8. **Check what the platform does by default.** `default-allow-ssh` did
   not appear in any of my Terraform; it appeared in the VPC. Look at
   what the console shows, not only at what you wrote.
9. **Silently-dropped IAM is the worst failure mode.** A binding for a
   role that does not exist is accepted and stored as empty. Nothing
   errors. Verify permissions by impersonating the principal and doing
   the actual work.
10. **Google's service agents are plural.** The monitoring agent and the
    monitoring *notification* agent are different accounts. Granting the
    wrong one looks exactly like granting the right one.
11. **When a tool's docs and its behaviour disagree, the behaviour wins.**
    `uptime_check/check_failed` is in every tutorial and does not exist
    while your site is healthy.
12. **A number you have not added up is not a measurement.** The cost
    table claimed $1.40/mo when the line items summed to $0.53 — it was
    a two-month total wearing a monthly label. The RPO was quoted from
    a log line instead of subtracted from two timestamps. Cheap
    arithmetic, and it caught more than any amount of rereading.
13. **A plan that always shows a diff is a plan nobody reads.** Three
    sources of permanent drift were hiding in plain sight — most
    absurdly, `gcloud compute ssh` appends a key to the instance
    metadata, so **logging in made Terraform want to replace the
    primary site**. Real drift does not get noticed while it is
    camouflaged as noise. `terraform plan` on an unchanged project
    should say "no changes", and if it does not, something is wrong
    with the project, not with the plan.
14. **Knowing the cost of a thing is not the same as affording it.**
    The cross-project backup replica was the strongest possible answer
    to the ransomware question, and the right call was still to leave it
    out of a $300 shared budget — documenting the design, shipping the
    controls that fit, and saying plainly which attacker is not covered.
15. **Read the pricing page, then measure it.** Rotating a KMS key does
    NOT retire the old version — it stays ENABLED and stays billed,
    forever. The cost table said $0.12/mo and was right that day, and
    wrong a year later. Every platform behaviour I had *read about*
    turned out to be subtly different from what the platform *does*.
16. **Ship one thing you can prove over two things you can only claim.**
    Every "this would be better with…" improvement in a portfolio
    project has to be weighed against the budget it consumes and the
    time it takes from the things you *have* measured.
