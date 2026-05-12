# Journey: GCP VPN Server (WireGuard)

Timeline: 7 working days spread over ~2 weeks. Constraint throughout:
**student free account** ($300 trial credits + always-free tier) — every
decision below was filtered through "does this burn credits I'll need for
the other 6 projects?"

---

## Day 1: Requirements before technology

**What I actually needed** (wrote this down before touching the console):
1. Secure access to private resources from untrusted networks (café/campus Wi-Fi)
2. 1–3 clients (laptop + phone), not a fleet
3. Full control over keys and logs — no third-party trust
4. Near-zero monthly cost
5. Something that demonstrates VPC/firewall/networking skills, not a SaaS signup

**Options I evaluated:**

| Option | Cost/mo | Control | Meets need | Verdict |
|--------|---------|---------|-----------|---------|
| Commercial VPN (Nord/Mullvad) | $5–12 | None (their servers, their logs) | ✗ #3, #5 | Rejected |
| Tailscale (free tier) | $0 | Medium (coordination server is theirs) | ✗ #3, #5 | Rejected — great product, but demonstrates nothing about my infra skills |
| Cloud VPN (GCP managed) | ~$36 ($0.05/hr/tunnel) | High | ✗ #4 | Rejected — designed for site-to-site, overkill and over-budget |
| OpenVPN on a VM | ~$0 (free tier) | Full | ✓ but heavy | Runner-up |
| **WireGuard on a VM** | ~$0 (free tier) | Full | ✓ all 5 | **Chosen** |

**Why WireGuard over OpenVPN specifically:** ~4k lines of code vs ~70k
(auditable, smaller attack surface), in-kernel since Linux 5.6 (no
userspace copy overhead), config is ~10 declarative lines (templatable in
a startup script vs OpenVPN's PKI ceremony with easy-rsa). The trade-off
I accepted: UDP-only, so it fails on networks that block all UDP —
acceptable for my usage; OpenVPN-over-TCP/443 would be the fallback if not.

**Cost impact:** $0 either way — the decision was about attack surface and
operational simplicity, not money.

## Day 2: Network design — spend where it matters, which is nowhere

**Decision:** Custom-mode VPC, single /28 subnet, us-east1.

**Analysis:** Auto-mode VPC creates a subnet in every region (~40). That's
40 places to accidentally create a billable resource and 40 subnets of
attack surface for a project that needs exactly one. Senior habit: the
default network is for demos; production teams delete it on day one.

**Region choice was budget-driven:** the always-free e2-micro allowance
only applies in us-east1, us-west1, us-central1. Picking any other region
would silently bill ~$6.11/mo against my credits. Latency from my location
was acceptable (~120 ms RTT through tunnel).

**Subnet sizing:** /28 (11 usable IPs). I only need 1. Over-provisioning
IPs is free, but a small CIDR documents intent — anyone reading the
Terraform knows this network hosts a single-purpose appliance.

**Also enabled Private Google Access** — costs nothing, and means any
future internal-only VM in this subnet can reach GCP APIs without a
public IP (which *would* cost money via Cloud NAT).

## Day 3: The SSH mistake

**Problem:** To get moving quickly I allowed SSH from 0.0.0.0/0. Within
hours, firewall logs showed ~200 connection attempts/day from scanner
botnets.

**Investigation:** Enabled firewall rule logging, filtered Cloud Logging
on `jsonPayload.disposition="ALLOWED"` for port 22 — the source IPs were
classic mass-scanners (Shodan-style ranges).

**Solution in two layers:**
1. Immediate: restricted the rule to my-home-IP/32.
2. Structural: added a Terraform `validation` block that **rejects**
   `0.0.0.0/0` for `admin_ip_cidr`. The mistake is now unrepeatable —
   by me or by anyone who forks this repo.

**Lesson:** "Works" ≠ "secure." And the senior-dev version of that lesson:
don't just fix the config, **make the unsafe state unrepresentable in code**.

## Day 4: Verify before you trust — performance testing

**Question I needed answered:** can a shared-core e2-micro actually carry
my traffic, or did I under-size to save money?

**Method:** iperf3 through the tunnel from 3 concurrent clients; monitored
CPU with `top` and GCP metrics during the run.

**Result:** ~150 Mbps sustained — far above my ~50 Mbps expectation for a
burstable shared-core VM. WireGuard's kernel implementation is the reason;
OpenVPN (userspace) benchmarks at roughly a third of that on equal hardware.

**Trade-off accepted:** e2-micro's CPU bursting means *sustained*
multi-client saturation would throttle. For 1–3 clients this never
materializes. Documented e2-medium as the first upgrade step and moved on —
optimizing beyond measured need is waste.

## Day 5: NAT keepalive bug

**Problem:** Phone client worked, then silently died after ~2 minutes idle.
Reconnecting fixed it — classic symptom of state expiring somewhere.

**Investigation:** `wg show` on the server: handshake stale. `tcpdump -ni
any udp port 51820`: server responses leaving, nothing arriving back. So
the path *to* the client was broken — my home router had expired the UDP
NAT mapping, and WireGuard (silent by design) sent nothing to refresh it.

**Solution:** `PersistentKeepalive = 25` on client configs — below typical
NAT table timeouts (30–60s).

**Lesson:** stateless protocols still depend on stateful middleboxes.
When debugging tunnels, capture on **both** ends before theorizing.

## Day 6: Cost optimization pass (the FinOps day)

Did a deliberate line-by-line review of what this project can bill:

| Line item | Risk | Action taken |
|-----------|------|--------------|
| e2-micro compute | $0 while in free-tier region | Already us-east1 ✓ |
| Static IP **attached to running VM** | $0 (free while in use) | ✓ |
| Static IP **while VM is stopped** | ~$7.30/mo — silent killer | Documented; release IP or destroy when idling long-term |
| Boot disk | 10 GB, within 30 GB free allowance | ✓ |
| Egress | ~$0.12/GB — the only true variable | Don't route streaming through the tunnel |
| Firewall rule logging | Free tier covers this volume | ✓ |

**Changes made today:**
1. **Billing alerts** at $50/$100/$150/$200/$250 on the account (console —
   budgets aren't worth Terraform-managing for a personal account).
2. **Auto-shutdown schedule** added to Terraform (`enable_auto_shutdown`):
   a Compute Engine instance schedule stops the VM at 01:00 nightly. A VPN
   I'm not using at 3 AM is pure idle burn if I ever move off the free
   tier or fall out of it. Start is manual — a VPN should come up when
   *I* decide, and `gcloud compute instances start` takes 20 seconds.
3. **Discovered the trade-off between #2 and the static IP** — a stopped
   VM makes its static IP billable (~$0.24/day). At free-tier compute
   prices, nightly shutdown *costs more than it saves*. So the schedule
   defaults **off**, fully wired and tested, ready for the day this runs
   on billable compute. Documented the math instead of cargo-culting
   "always auto-shutdown."

**Lesson:** cost optimization is arithmetic, not folklore. The "obvious"
saving (shut it down!) was net-negative in my exact configuration.

## Day 7: Encode the lessons, then leave

Final pass with the question: *if I got hit by a bus, could someone
reproduce this?*

- **CI added:** `terraform fmt -check`, `terraform validate`, and
  ShellCheck on every push — the repo can't drift into an unbuildable state.
- **Idempotency check:** re-ran the startup script on a live VM — marker
  file guards it; keys survive reboots. Recreating the *VM*, however,
  regenerates server keys and orphans every client. Documented loudly in
  troubleshooting; the production fix (keys in Secret Manager) is in the
  scaling doc — deliberately not built, because for a demo it adds an API
  dependency and a per-secret cost for zero demo value.
- **Ran `terraform destroy && terraform apply` end-to-end:** 4 minutes to
  a working VPN from nothing. That number is the whole point of IaC.

**What I'd do differently next time:** start with the firewall validation
rules on day 1 instead of learning them on day 3. Requirements analysis
before code was the right call; I'd add "abuse analysis" (who will scan
this?) to the same session.


- **Verified deployment end-to-end from CLI**: VM `wireguard-vpn` in
  `portfolio-vpn-2026` (`us-east1-b`), wg0 up, phone1 client admitted and
  confirmed working by user (speed "near native").

## Day 9: Per-device activity logging + the duplicate-CONNECT bug

Goal: ISP-style per-device activity logging (like a home router shows
"which device was online when") so the VPN server answers "what was my
phone doing and when" without any client-side install.

- **Built `wg-activity-log.sh`** — reads `wg show wg0 dump`, maps peers to
  names via the `# client: <name>` comments in `wg0.conf`, and emits
  `CONNECT` / `DISCONNECT` / traffic-summary lines to
  `/var/log/wg-activity.log`.
- **Packaged as systemd timer** (`wg-activity.{service,timer}`) running
  every minute, plus logrotate (weekly x8). Deployed to
  `/usr/local/sbin/`, `/etc/systemd/system/`, enabled and active.
- **Normalized the peer comment** for phone1 (`# phone1` → `# client: phone1`)
  so the name mapping works.

**The bug:** the first run *worked*, then every subsequent run logged a
duplicate `CONNECT phone1` — the log showed two connects ~1 min apart with
zero traffic delta.

**Root cause — a state-file read/write mismatch:** the state file was
written as `ts=… prev_rx=… prev_tx=…` but the script *read* `prev_ts=…`.
`prev_ts` never matched a written key, so it stayed at its default `0`,
making the "was this peer previously connected?" check always look stale →
`CONNECT` logged every single run. `prev_rx`/`prev_tx` matched their
written names, so traffic deltas were correct (0) — which made the bug look
like an intermittent logging hiccup rather than a logic error.

**Fix:** rewrote the active-check around a deterministic `was_active` flag
(0/1) written *and* read with the same name, replacing the fragile
timestamp-staleness check. State file now `was_active=… prev_rx=… prev_tx=…`.
Verified on the VM: syntax check, clean state reset, single run clean;
behavior test (toggle off/on → one CONNECT, one DISCONNECT ~3 min later)
recorded as TODO so the user can confirm from the client side.

**Lesson:** name your persisted-state keys and your reads the same string.
A misspelled/renamed key silently degrades into "always default" — the
logical equivalent of an uninitialized variable, but invisible because the
first run masked it. Grep the state file format against the parse before
assuming the logic is wrong.

**Also documented:** full credentials + every common command in
`keys/CREDENTIALS.md`; a running roadmap in `TODO.md` (DuckDNS on-demand,
Terraform-managed logger, GCS state, 6 remaining projects).

---

## Day 10: TODO cleanup — quick wins on a different machine

**What:** cleaned up 5 TODO items (log dedup, key rotation docs, billing
alerts, PROJECTS.md, firewall IP update) from a Fedora backup of the repo.

**Why:** these were all low-effort, high-value items blocking the "this
project is done" milestone. Doing them from a different machine was also
a portability test — can someone else (or future-me on a new laptop) pick
up this project cold?

**How:** SSHed into the VM for log cleanup, wrote docs locally, created
billing budget via gcloud console (CLI had a SDK bug), updated tfvars
for the new machine's IP.

### Key decisions

1. **SSH IP update via gcloud CLI, not Terraform:** changing `admin_ip_cidr`
   in tfvars + `terraform apply` would work but takes 30s of planning +
   apply. `gcloud compute firewall-rules update` is instant (3s). The
   tfvars file was also updated to keep Terraform as the source of truth,
   but the live fix was CLI-first because urgency (can't SSH) trumps
   process purity.

2. **Billing alerts via console, not CLI:** the gcloud SDK 578.0.0 has a
   known bug where `billingbudgets.googleapis.com` requires a quota project
   header that the CLI doesn't send. Upgrading the SDK for a one-time
   operation isn't worth the risk of breaking other gcloud workflows. The
   console is the right tool for one-shot billing setup.

3. **PROJECTS.md as index, not documentation:** the README covers the VPN
   project. PROJECTS.md answers "what else is in this GCP account?" — a
   question that matters when the portfolio grows to 6+ projects. It's a
   lookup table, not a narrative.

### Portability test result

The project worked from a Fedora backup with zero code changes. The only
friction was:
- Different package manager (no pacman → manual kubectl binary)
- Different IP (firewall rule update)
- gcloud auth re-login (expected — credentials don't transfer with git)

This validates the "student free account" constraint: the project is
entirely self-contained. No secrets in git, no hardcoded paths (except
SSH key in CREDENTIALS.md which is gitignored), no host-specific deps
beyond the three tools (terraform, gcloud, kubectl).

### Updated TODO status

| Item | Status | Notes |
|------|--------|-------|
| Clean duplicate-CONNECT rows | DONE | 252 → 249 lines, backup preserved |
| Client key rotation docs | DONE | Added to troubleshooting.md |
| Billing budget alerts | DONE | Existing + console-created $300 USD |
| PROJECTS.md | DONE | Active + deleted + planned |
| Ship logger via Terraform | DONE | Embedded in startup.sh as heredocs |
| GCS backend for state | DONE | `portfolio-vpn-2026-tfstate` bucket, versioned |
| Confirm live VPN toggle test | PENDING | User must toggle phone VPN |

---

## Day 11: Terraform hardening — activity logger in startup, GCS state backend

**What:** two medium-effort TODO items — embed the activity logger in
the startup script (eliminating manual `scp` deployment) and migrate
Terraform state from local to GCS (eliminating the single-point-of-
failure laptop).

**Why:** these two changes close the gap between "demo that works" and
"reproducible infrastructure." Before: `terraform apply` = VPN without
logging, state lives on one laptop. After: `terraform apply` = complete
VPN with logging, state is crash-proof and versioned.

**How:** embedded files as heredocs in startup.sh, created GCS bucket,
added backend config, ran `terraform init -migrate-state`.

### 1. Activity logger in startup.sh

**What:** embedded `wg-activity-log.sh`, `wg-activity.service`,
`wg-activity.timer`, and logrotate config as heredocs inside `startup.sh`.

**Why:** the logger was previously deployed via manual `scp + sudo mv +
systemctl enable`. This meant every `terraform apply` on a fresh VM
produced a VPN without logging — requiring the same manual steps every
time. For a demo project that prides itself on "4 minutes from zero to
working VPN," manual steps defeat the purpose.

**How:** heredocs inside the startup script (which already runs on first
boot via GCE metadata). The marker file guard ensures idempotency. No
separate provisioning step, no file upload, no dependency on GCS or
external tools.

**Why heredocs instead of `copy_files` metadata?** GCE metadata
startup_script has a 256KB limit. The full script (WireGuard setup +
hardening + activity logger) is ~4KB — well within limits. The heredoc
approach keeps everything in one file, one idempotent pass, one marker
guard. No separate provisioning step, no file upload, no dependency on
GCS or external tools.

**Trade-off:** the startup script is now ~170 lines (was ~85). It's
still a single-purpose script that runs once, so readability is fine.
If it grew past ~300 lines I'd consider splitting into a setup script
+ a separate logger installer, but that would add complexity for no
operational benefit at this scale.

### 2. GCS backend for Terraform state

**What:** created GCS bucket `portfolio-vpn-2026-tfstate` (us-east1,
versioned), added `backend "gcs"` to `versions.tf`, migrated state via
`terraform init -migrate-state`.

**Why:** local `terraform.tfstate` is a single point of failure. If the
laptop dies, the state is gone — and `terraform plan` would show "create
everything from scratch," which would destroy the live VPN. GCS gives us
crash-proof storage, version history (rollback bad applies), and multi-
user capability (team members can work from the same state).

**How:** `gsutil mb` to create the bucket, `gsutil versioning set on`
for rollback support, `terraform init -migrate-state` to upload the
existing local state. The local `terraform.tfstate` is kept as backup
(gitignored).

**Cost:** GCS standard storage is $0.020/GB/month. Terraform state is
~50KB. That's $0.001/year — effectively free.

**The plan after migration:** `terraform plan` shows 1 to add, 0 to
change, 1 to destroy. The destroy is the VM — because the startup
script changed (activity logger added). This is expected: GCE replaces
the instance when `metadata_startup_script` changes. The plan also
corrects some attribute drift from the newer Google provider version
(5.45.2 vs whatever was used at initial deploy).

**Why I did NOT apply:** `terraform apply` would destroy the running VPN
(~4 min downtime). The user needs to schedule this during a maintenance
window. The current VPN works fine — the activity logger is already
installed manually. The apply is a "next time you need to recreate the
VM" operation, not an urgent fix.

### What "production-grade" means here

Before today:
- `terraform apply` = working VPN, no logging
- `scp` + manual steps = logging
- State on laptop = single point of failure

After today:
- `terraform apply` = working VPN with activity logging, fully automated
- State in GCS = crash-proof, versioned, multi-user capable
- Zero manual steps for a fresh deployment

This is the difference between "demo" and "reproducible infrastructure."
The 4-minute end-to-end test (`terraform destroy && terraform apply`)
now produces a complete, logged, hardened VPN — no human in the loop.

### Terraform apply: the real test

**What:** ran `terraform apply` to recreate the VM with the new startup
script (activity logger embedded).

**Why:** the startup script changed, and GCE replaces the instance when
`metadata_startup_script` changes. This also validates the full
"destroy + apply = working VPN" loop that is the whole point of IaC.
Credits are available, downtime is acceptable.

**How:** `terraform plan -out=tfplan` to preview, `terraform apply tfplan`
to execute. VM destroyed and recreated in 45 seconds. Same IP
(`34.24.249.96`), same VPC, same firewall rules. New server public key
(`eCcryuh9...`) — expected since keys are generated on first boot.

**Post-apply verification:**
- WireGuard up, listening on port 51820
- Activity timer enabled and running (first trigger ~2 min after boot)
- Logger script installed at `/usr/local/sbin/wg-activity-log.sh`
- Logrotate config in place
- `add-client.sh` works end-to-end (re-added phone1, got QR code)

### Bug found during apply: add-client.sh fails on fresh server

**What:** `add-client.sh phone1` exited silently with code 1 on the
new VM (no existing peers).

**Why it matters:** this is the first thing you run after a fresh deploy.
If it fails, the VPN is up but has no clients — useless. The bug was
invisible on the original VM because phone1 already existed.

**Root cause:** line 23 runs `grep -oP 'AllowedIPs...' | cut | sort -n`.
When there are no peers, `grep` finds nothing and exits 1. With
`set -euo pipefail`, the pipeline failure propagates and kills the
script before it reaches the `for i in $USED` loop (which would have
correctly handled empty input).

**Fix:** added `|| true` to the pipeline:
```bash
USED=$(grep -oP 'AllowedIPs\s*=\s*\K[\d.]+' "$WG_CONF" | cut -d. -f4 | sort -n || true)
```

**Why `|| true` and not removing `pipefail`?** `pipefail` catches real
errors elsewhere in the script (e.g., `wg genkey` failing). The issue
is specifically that `grep` returning "no matches" is not an error —
it's a valid empty result. `|| true` converts that valid-empty into
exit 0, which `pipefail` accepts.

**Lesson:** test scripts on empty state, not just populated state. A
`grep` that returns nothing isn't an error — but with `pipefail`, it
becomes one.

### Updated final state

| Component | Status |
|-----------|--------|
| VM | `wireguard-vpn` running, Debian 12, e2-micro, us-east1 |
| WireGuard | wg0 up, port 43226, server key `uAga7d94...` |
| Clients | phone1 at `10.200.200.2`, endpoint `gcp-vpn.duckdns.org:51820` |
| DuckDNS | `gcp-vpn.duckdns.org` → ephemeral IP, updater every 5 min |
| Auto-shutdown | Nightly at 01:00 UTC (safe now — no static IP billing) |
| Wake-on-demand | Cloud Function `wake-vpn` (token auth, starts VM via API) |
| Activity logger | systemd timer active, logging to `/var/log/wg-activity.log` |
| Terraform state | GCS backend `portfolio-vpn-2026-tfstate/vpn-server` |
| Firewall | SSH from `[home-ip]/32`, WireGuard from anywhere |
| Security | UFW + fail2ban + unattended-upgrades + Shielded VM |
| add-client.sh | Fixed `pipefail` bug, uses DuckDNS hostname |

_Last updated: 2026-08-11_

---

## Day 12 — Dynamic DNS with DuckDNS

**What:** Added DuckDNS dynamic DNS so client configs use `gcp-vpn.duckdns.org` instead of a hardcoded IP. This unlocks the ability to switch to an ephemeral IP later and stop the VM when idle without losing connectivity.

**Why:** A reserved static IP costs ~$0.24/day even when the VM is off. With DuckDNS + ephemeral IP, a stopped VM truly costs $0. The VPN becomes pay-when-you-use, not pay-all-the-time.

**How:**
1. Created `duckns-update.sh` — script that curls DuckDNS API with current public IP
2. Added systemd service + 5-min timer to run the updater automatically
3. Added logrotate config for the updater log
4. Embedded DuckDNS setup in `startup.sh` — reads domain/token from VM metadata attributes
5. Added DuckDNS variables to Terraform (module + root + tfvars, token gitignored)
6. Re-ran `terraform apply` to recreate VM with DuckDNS metadata
7. Verified: timer active, `gcp-vpn.duckdns.org` resolves to `34.24.249.96`
8. Re-added phone1 — config now uses `gcp-vpn.duckdns.org:51820` as endpoint
9. Updated CREDENTIALS.md with new server key + DuckDNS hostname

**Then: switched to ephemeral IP (same day)**

Removed `google_compute_address.vpn_ip` from Terraform. VM now gets a random IP on boot. DuckDNS tracks it automatically. Enabled nightly auto-shutdown (now safe — no static IP billing when stopped).

- Old static IP: `34.24.249.96` (released)
- New ephemeral IP: `35.237.241.221` (will change on next stop/start)
- `gcp-vpn.duckdns.org` already resolves to the new IP ✅
- Cost impact: stopped VM = $0/day (was ~$0.24/day with reserved IP)

**Then: added wake-on-demand Cloud Function (same day)**

Deployed a Cloud Function that starts the VM via GCP API when called with a secret token. This completes the on-demand VPN cycle: stop VM → costs $0 → wake from phone → connect.

- Function URL: `https://us-east1-portfolio-vpn-2026.cloudfunctions.net/wake-vpn`
- Auth: secret token in query param (`?token=<wake_token>`)
- From phone: `curl "https://...?token=..."` → VM starts → wait ~1 min → WireGuard connects
- Terraform manages: function, service account, IAM, source bucket

**Then: randomized UDP port (same day)**

Changed WireGuard from default port 51820 to random port 43226. Port 51820 is well-known and constantly scanned by bots. Random port reduces log noise and attack surface.

- Old port: 51820 (WireGuard default, heavily scanned)
- New port: 43226 (random, not in any common scan list)
- Updated: UFW on VM, GCP firewall rule, WireGuard config, Terraform metadata
- Client configs regenerated with new port endpoint

**Then: added VPN health monitoring (same day)**

Deployed Cloud Scheduler + Cloud Function to check VPN health every 5 minutes. Resolves DuckDNS hostname, tests WireGuard UDP reachability, writes custom metric (`vpn/health`) to Cloud Monitoring.

- Function: `vpn-health` — checks DNS + WireGuard port reachability
- Scheduler: `vpn-health-check` — runs every 5 minutes
- Custom metric: `custom.googleapis.com/vpn/health` (1=UP, 0=DOWN)
- Logs to Cloud Logging with ALERT prefix when DOWN
- Dashboard: view in Cloud Monitoring → Metrics Explorer → vpn/health



*All future improvements tracked in [docs/TODO.md](docs/TODO.md).*

---

## Day 12 (continued): Dynamic IP reconnection fix

**Problem identified**: WireGuard clients couldn't reconnect after server IP changed (stop/start). Two root causes:

1. **Server-side**: Startup script only ran DuckDNS update on first boot (`[ -f "$MARKER" ] && exit 0` at top). After a reboot with the marker file, DuckDNS never updated — so DNS pointed to stale IP.

2. **Client-side**: WireGuard resolves endpoint DNS only once at startup. With `AllowedIPs = 0.0.0.0/0` (full tunnel), all traffic routes through the VPN including DNS. When the tunnel drops (server IP changed), the client can't re-resolve the hostname to find the new IP.

**Fixes applied**:

- **Startup script restructured**: DuckDNS setup moved BEFORE the marker check. Now runs on every boot. WireGuard setup remains first-boot-only.
- **DuckDNS interval reduced**: From 5 min to 1 min (OnBootSec=30sec, OnUnitActiveSec=1min). Faster propagation after IP changes.
- **Client behavior**: Android/iOS WireGuard app re-resolves DNS every 2 min automatically — works out of the box. Desktop `wg-quick` does NOT re-resolve — needs manual `wg-quick down wg0 && wg-quick up wg0` or a reconnect script.
- **End-to-end verified**: Stop → wake via Cloud Function → VM boots → DuckDNS updates → DNS resolves → WireGuard port accessible → phone1 peer connected.

**Unattended-upgrades decision**: Keep enabled. VM shuts down nightly at 01:00 UTC anyway, so reboots after kernel patches are "free." Security patches are more important than uptime for a portfolio VPN. If a bad update breaks WireGuard, the nightly shutdown cycle surfaces it quickly.

**Secret Manager decision**: Skip for now. Keys are on an encrypted disk with UFW/fail2ban. Adds complexity + IAM setup for minimal benefit. Revisit if this becomes a production service.

**Server public key** (rotated during VM recreate): `7MnOBiYfDMJojAb+Ah+AQEKawgW4oRcs4PLA/AqLflw=`

---
