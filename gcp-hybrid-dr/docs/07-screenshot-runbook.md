# Screenshot Runbook — gcp-hybrid-dr

A step-by-step script for capturing the screenshots that prove this
project works. Follow it in order; each step says **what to capture**,
**exactly how**, and **why that shot matters**.

Screenshots land in `assets/screenshots/` with dated filenames, matching
the convention used by the other projects in this portfolio.

---

## Before you start

### 0.1. Prerequisites

```bash
# From the project root
cd ~/Projects/GCP/gcp-hybrid-dr

# You need: gcloud (logged in), terraform, jq, dig, and a terminal
# that renders colour (for the Cloud Console screenshots, use a browser).
gcloud auth list          # expect your account with a green check
terraform version         # >= 1.5
```

### 0.2. Confirm the project is still up

```bash
# From the project root
cd terraform

PROJECT_ID=$(terraform output -raw project_id)
PRIMARY_IP=$(terraform output -raw primary_ip)
DR_URI=$(terraform output -raw dr_service_uri)
RESOLVER=$(terraform output -json dns_name_servers | jq -r '.[0]')
ZONE=$(terraform output -raw dns_name)
PUBLIC_RECORD=$(terraform output -raw dns_public_record)

cd ..

echo "project  : $PROJECT_ID"
echo "primary  : $PRIMARY_IP"
echo "standby  : $DR_URI"
echo "resolver : $RESOLVER"
echo "zone     : $ZONE"
echo "public   : $PUBLIC_RECORD"
```

Expected:

```
project  : gcp-hybrid-dr
primary  : 34.23.59.120
standby  : https://dr-demo-dr-maintenance-....a.run.app
resolver : ns-cloud-b1.googledomains.com.
zone     : dr-demo.gcp-hybrid-dr.example.com.
public   : www.dr-demo.gcp-hybrid-dr.example.com.
```

If `terraform output` fails, the state is not reachable — see
[Troubleshooting](docs/05-troubleshooting.md).

> `terraform output -raw` does not work for list-valued outputs, which is
> why `dns_name_servers` is read with `jq`.

### 0.3. Make the screenshot directory

```bash
mkdir -p assets/screenshots
```

### 0.4. Set up a clean terminal for the captures

Screenshots of a terminal are much more readable with a predictable
window size and a timestamp. This one-liner gives you a compact,
timestamped prompt:

```bash
export PS1='\[\e[32m\]\$ \[\e[0m\]\D{%H:%M:%S} '
```

Set the terminal to a fixed size so the text is not clipped:
**~100 columns × ~30 rows**. On GNOME Terminal: `Ctrl+Shift+M` is
"Preferences" → but the simplest reliable approach is to maximise the
window and use a smaller font, or just capture at whatever size and
crop later.

---

## Part 1 — The site is alive and serving real data

### Shot 1.1 — The primary site, serving real orders

**Why:** it proves the app is not a mock. A reviewer wants to see
actual rows out of an actual database.

```bash
curl -s http://${PRIMARY_IP}/ | head -c 600
```

**Or, in a browser:** open `http://${PRIMARY_IP}/`.

You should see the ACME Orders table with five rows (`ORD-1001` …
`ORD-1005`).

**Capture:** the browser page. Name it `assets/screenshots/YYYY-MM-DD-primary-orders.png`.

> The site is plain HTTP on a bare IP — there is no TLS without a
> registered domain, and that is documented in
> [docs/03-security.md](docs/03-security.md). A browser may show a
> "not secure" badge; that is expected, not a defect.

### Shot 1.2 — The health endpoint

**Why:** this is the exact URL the monitoring uptime check probes. It is
the input to the whole failover chain.

```bash
curl -s http://${PRIMARY_IP}/health
```

Expected:

```json
{"host":"dr-demo-primary","site":"primary","status":"ok","time":"2026-10-22T..."}
```

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-primary-health.png`.

---

## Part 2 — The backup pipeline, proven end to end

### Shot 2.1 — A backup, uploaded and verified

**Why:** the single most important claim in the project is that backups
actually work. This shows the checksum, the gzip, the integrity check
and the recovered row count in one line.

```bash
bash src/scripts/verify-backup.sh gcp-hybrid-dr-dr-demo-backups
```

Expected:

```
latest backup: gs://gcp-hybrid-dr-dr-demo-backups/backups/app-2026...db.gz
app-2026...db.gz: OK
OK: checksum verified, gzip intact, integrity_check ok, 5 order rows
backup age: 0h (RPO target: <24h)
```

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-backup-verified.png`.

### Shot 2.2 — The bucket listing, source and replica

**Why:** shows the cross-region replica is real, not just configured.

```bash
echo "--- source (us-east1) ---"
gcloud storage ls gs://gcp-hybrid-dr-dr-demo-backups/backups/ | tail -6
echo "--- replica (us-west1) ---"
gcloud storage ls gs://gcp-hybrid-dr-dr-demo-backups-replica/backups/ | tail -6
```

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-cross-region-replication.png`.

### Shot 2.3 — The write-only guarantee, from inside the VM

**Why:** this is the security claim that a reviewer is most likely to
doubt. The primary VM's service account can *write* backups and
*cannot read* them — proven by a 403 from the machine itself.

```bash
gcloud compute ssh dr-demo-primary --zone us-east1-b --project gcp-hybrid-dr \
  --command 'gcloud storage ls gs://gcp-hybrid-dr-dr-demo-backups/backups/ 2>&1 | tail -2'
```

Expected: `HTTPError 403: ... does not have storage.objects.get access`.

Then, in the same session, show that a *write* succeeds:

```bash
gcloud compute ssh dr-demo-primary --zone us-east1-b --project gcp-hybrid-dr \
  --command 'sudo /opt/dr/backup.sh 2>&1 | tail -3'
```

Expected: `uploaded gs://.../app-...db.gz (crc32c ...)`.

**Capture:** the terminal, both commands. `assets/screenshots/YYYY-MM-DD-write-only-iam.png`.

### Shot 2.4 — The restore drill

**Why:** a backup you have never restored is a hope, not a backup. This
is the automated weekly drill proving the newest backup is usable.

```bash
gcloud pubsub topics publish dr-demo-restore-drill-tick --project gcp-hybrid-dr \
  --message='{"check":"restore-drill"}'
sleep 45
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="dr-demo-restore-drill"' \
  --project gcp-hybrid-dr --limit=2 \
  --format='value(timestamp,severity,jsonPayload.message,jsonPayload.order_rows)'
```

Expected: `RESTORE_DRILL_PASS: newest backup downloaded, checksum verified, gzip intact, integrity ok` with `order_rows = 5`.

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-restore-drill-pass.png`.

### Shot 2.5 — The freshness sentinel

**Why:** shows the RPO monitor actually reading the bucket.

```bash
gcloud pubsub topics publish dr-demo-backup-freshness-tick --project gcp-hybrid-dr \
  --message='{"check":"backup-freshness"}'
sleep 40
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="dr-demo-backup-freshness"' \
  --project gcp-hybrid-dr --limit=2 \
  --format='value(timestamp,severity,jsonPayload.message,jsonPayload.age_hours)'
```

Expected: `backup fresh: backups/app-...db.gz is 0.1h old (limit 24h)`.

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-rpo-freshness.png`.

---

## Part 3 — The failover (the money shot)

This is the part that no diagram can replace. It takes about 12
minutes end to end.

### Shot 3.1 — Before: DNS points at the primary

```bash
dig @${RESOLVER} www.${ZONE} CNAME +short
```

Expected:

```
primary.dr-demo.gcp-hybrid-dr.example.com.
```

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-dns-before.png`.

### Shot 3.2 — Run the drill

```bash
bash src/scripts/disaster-drill.sh \
  --project ${PROJECT_ID} \
  --zone us-east1-b \
  --instance dr-demo-primary \
  --dns-name ${PUBLIC_RECORD} \
  --resolver ${RESOLVER} \
  --poll 15 \
  --timeout 720 2>&1 | tee ~/drill.log
```

Leave it running. It will:

1. stop the primary VM (a **real** outage)
2. poll the public name against the authoritative nameserver
3. wait for the alert to fire, the record to flip, and the standby to answer
4. restart the VM and wait for the record to be restored

**Capture the terminal DURING the drill**, at the moment the DNS flips.
The output looks like:

```
[2026-10-22T17:43:18+00:00] stopping dr-demo-primary (simulated disaster)
[2026-10-22T17:43:40+00:00] VM stopped (+22s)
[2026-10-22T17:50:59+00:00] DNS www.dr-demo... -> dr-demo-dr-maintenance-...a.run.app.
[2026-10-10-22T17:50:59+00:00] endpoint answering 200 on /health via dr-demo-dr-maintenance-...
[2026-10-22T17:50:59+00:00] restarting dr-demo-primary
[2026-10-22T17:54:48+00:00] DNS restored -> primary.dr-demo... (primary)

=== MEASURED RTO ===
disaster injected : 2026-10-22T17:43:18+00:00
DR serving users  : +461s
```

**Capture** the whole terminal window at the "DNS -> ...a.run.app" line.
`assets/screenshots/YYYY-MM-DD-failover-rto.png`.

### Shot 3.3 — The DR standby serving users

**Why:** proves users actually reach something during the outage.

While the drill is between "flip" and "restart" (about a minute
window — widen it by setting `--poll 30` if you miss it), or right
after the flip:

```bash
# What the public name now resolves to
dig @${RESOLVER} www.${ZONE} CNAME +short

# The standby answers 200 on /health
curl -s https://$(echo ${DR_URI} | sed 's|https://||')/health

# ...and serves 503 + Retry-After for real requests, which is the
# correct semantic for a maintenance page
curl -si https://$(echo ${DR_URI} | sed 's|https://||')/ | head -6
```

Expected:

```json
{"status":"ok","site":"dr"}
```

and `HTTP/2 503` with a `Retry-After` header.

**Capture:** the terminal, and the browser at the standby URL (the
"Untitled / maintenance" page). `assets/screenshots/YYYY-MM-DD-dr-standby-503.png`.

### Shot 3.4 — After: DNS restored

```bash
dig @${RESOLVER} www.${ZONE} CNAME +short
```

Expected: `primary.dr-demo.gcp-hybrid-dr.example.com.`

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-dns-after.png`.

### Shot 3.5 — The failover function's own log

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="dr-demo-dns-failover"' \
  --project gcp-hybrid-dr --limit=6 \
  --format='value(timestamp,severity,jsonPayload.message)'
```

Expected: `FAILOVER_ACTIVATED: ... now points at the DR target` and
`FAILOVER_RECOVERED: ... restored to the primary target`.

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-failover-log.png`.

---

## Part 4 — The Cloud Console (browser screenshots)

Open the console at
<https://console.cloud.google.com/home/dashboard?project=gcp-hybrid-dr>.

### Shot 4.1 — The DR posture dashboard

**Why:** one screen showing all four DR signals — uptime, CPU, RPO
breaches and restore-drill failures.

**Path:** `Monitoring` → `Dashboards` → `dr-demo — DR posture`

**Capture:** the dashboard with all four charts visible.
`assets/screenshots/YYYY-MM-DD-dashboard.png`.

> **Heads-up:** the charts need data and the uptime widget reads the
> `check_passed` gauge (1 = passing). If a chart is empty, the metric
> has not been written yet — wait a few minutes, or run the freshness
> and drill functions from Part 2 to force some data.

### Shot 4.2 — The alert policies

**Path:** `Monitoring` → `Alerting` → `Policies`

You should see four policies:

- `Primary site DOWN — /health failing (dr-demo)`
- `Primary VM CPU > 90% for 10 minutes (dr-demo)`
- `RPO breach — backup older than 24h`
- `Restore drill FAILED — newest backup not restorable`

**Capture:** the policy list. `assets/screenshots/YYYY-MM-DD-alert-policies.png`.

### Shot 4.3 — The incident that fired

**Path:** `Monitoring` → `Alerting` → `Incidents`

After a drill, the primary-down incident appears here with its open and
closed timestamps — which is the independent record of the RTO.

**Capture:** the incident row. `assets/screenshots/YYYY-MM-DD-incident.png`.

### Shot 4.4 — The Cloud Run standby (scale to zero)

**Path:** `Cloud Run` → `dr-demo-dr-maintenance` → `us-west1`

**Capture:** the service page showing 0 requests and 0 instances — the
"$0/mo until a disaster" claim.
`assets/screenshots/YYYY-MM-DD-cloudrun-scale-to-zero.png`.

### Shot 4.5 — The budget guardrail

**Path:** `Billing` → `Budgets & alerts`

**Capture:** the budget row showing the threshold percentages.
`assets/screenshots/YYYY-MM-DD-budget.png`.

### Shot 4.6 — The KMS key

**Path:** `Security` → `Cryptographic keys` → `dr-demo-backup-key`

**Capture:** the key page showing the 90-day rotation period.
`assets/screenshots/YYYY-MM-DD-kms-rotation.png`.

### Shot 4.7 — The buckets

**Path:** `Cloud Storage` → `Buckets` → `gcp-hybrid-dr-dr-demo-backups`

**Capture:** the bucket list showing both the backup and replica buckets
in different regions, and their labels.
`assets/screenshots/YYYY-MM-DD-buckets.png`.

---

## Part 5 — The engineering artifacts

### Shot 5.1 — The test suite passing

**Why:** 74 tests is the strongest single credibility signal in the
project.

```bash
.venv-test/bin/python -m pytest tests/ -q 2>&1 | tail -5
```

If `.venv-test` does not exist yet:

```bash
python3 -m venv .venv-test
.venv-test/bin/pip install -r requirements-dev.txt
```

**Capture:** the terminal showing the pass count.
`assets/screenshots/YYYY-MM-DD-tests-passing.png`.

### Shot 5.2 — A clean Terraform plan

**Why:** proves the IaC is not lying — a project whose plan always
shows drift is a project nobody can trust.

```bash
cd terraform
export GOOGLE_CLOUD_QUOTA_PROJECT=gcp-hybrid-dr
terraform plan -detailed-exitcode >/dev/null 2>&1
echo "plan exit: $? (0 = no changes)"
```

Expected: `plan exit: 0 (0 = no changes)`.

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-plan-clean.png`.

### Shot 5.3 — The Cloud Run / Functions / Schedulers inventory

```bash
gcloud functions list --project gcp-hybrid-dr --regions us-east1 \
  --format='table(name,state)'
gcloud scheduler jobs list --project gcp-hybrid-dr --location us-east1 \
  --format='table(name,schedule)'
```

**Capture:** the terminal. `assets/screenshots/YYYY-MM-DD-automation-inventory.png`.

### Shot 5.4 — The GitHub Actions run

After pushing, `https://github.com/neonite-rc/GCP-Projects/actions`

**Capture:** the green CI run. `assets/screenshots/YYYY-MM-DD-ci-green.png`.

---

## Part 6 — Adding the screenshots to the README

Once captured, add them to the README under a new **Screenshots**
section, after the "What Makes This Stand Out" section:

```markdown
## Screenshots

| | |
|---|---|
| ![Primary site serving real orders](assets/screenshots/YYYY-MM-DD-primary-orders.png) | ![Measured RTO from a live drill](assets/screenshots/YYYY-MM-DD-failover-rto.png) |
| **The primary site, serving real SQLite rows** | **A real outage, measured: 461s from VM stop to users served** |
| ![DR standby returns 503 + Retry-After](assets/screenshots/YYYY-MM-DD-dr-standby-503.png) | ![Backup verified end to end](assets/screenshots/YYYY-MM-DD-backup-verified.png) |
| **The standby serving users during the outage** | **Checksum verified, gzip intact, integrity ok, 5 rows recovered** |
| ![DR posture dashboard](assets/screenshots/YYYY-MM-DD-dashboard.png) | ![Write-only IAM, proven from inside the VM](assets/screenshots/YYYY-MM-DD-write-only-iam.png) |
| **All four DR signals on one screen** | **The VM can write backups and cannot read them** |
```

---

## Part 7 — Cleanup

The drill leaves the system in its healthy state, but confirm:

```bash
# The VM is running
gcloud compute instances describe dr-demo-primary --zone us-east1-b \
  --project gcp-hybrid-dr --format='value(status)'

# DNS points at the primary
dig @${RESOLVER} www.${ZONE} CNAME +short

# No stray test objects
gcloud storage ls gs://gcp-hybrid-dr-dr-demo-backups/backups/ | grep -i test || echo "clean"
```

Optional: remove the scratch keyring created while investigating the
KMS rotation behaviour. Key rings cannot be deleted, but an empty one
costs nothing:

```bash
gcloud kms keys list --keyring=dr-demo-dr-zone --location=us-east1 \
  --project gcp-hybrid-dr --format='value(name)'
# If it still lists keys, destroy their versions first, then the keys.
```

---

## Quick reference — the eleven shots that matter most

If time is short, these are the ones a reviewer will actually look at:

| # | Shot | Proves |
|---|------|--------|
| 1 | `failover-rto` | The DR strategy works, with a number |
| 2 | `dr-standby-503` | Users are served during the outage |
| 3 | `backup-verified` | Backups are real and restorable |
| 4 | `write-only-iam` | The security model is enforced, not claimed |
| 5 | `primary-orders` | It is a working app, not a mock |
| 6 | `dashboard` | The whole system is observable |
| 7 | `restore-drill-pass` | Backups are proven usable automatically |
| 8 | `cross-region-replication` | The DR copy actually exists |
| 9 | `tests-passing` | The code is tested |
| 10 | `plan-clean` | The IaC is trustworthy |
| 11 | `failover-log` | The automation did what it claims |

---

## Troubleshooting the capture

**The drill times out (`ERROR: no recovery within 900s`).**
The alert window is 300s and the drill waits 720s, so there is headroom —
unless the alert never fires. Check:
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="dr-demo-dns-failover"' \
  --project gcp-hybrid-dr --limit=5 --format='value(timestamp,jsonPayload.message)'
```
If the failover function logged nothing, the alert never fired — check
the `primary_down` policy's incident history in the console.

**`dig` returns nothing.**
The zone's nameservers differ per zone. Get them from Terraform, do not
hardcode:
```bash
cd terraform && terraform output -json dns_name_servers | jq -r '.[0]'
```

**A dashboard chart is empty.**
Metrics need time to be written, and the uptime widget reads the
`check_passed` BOOL gauge. Force some data by running the freshness and
restore-drill functions (Part 2), then wait a few minutes.

**`terraform output` fails in the shell.**
The remote backend needs credentials. Check:
```bash
cd terraform && terraform init -backend-config="bucket=gcp-hybrid-dr-tfstate"
```

**SSH into the VM times out.**
The firewall allows only `admin_ip_cidr`, and a residential IP changes.
Get the current one and update `terraform.tfvars`:
```bash
curl -4 -s https://ifconfig.me
```
Then `terraform apply` in `terraform/`.
