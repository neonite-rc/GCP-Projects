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
