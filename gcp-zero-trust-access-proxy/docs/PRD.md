# PRD: Self-Hosted GCP VPN Server (WireGuard + Tailscale Dual-Stack)

> **Status:** Draft — `needs-triage`
> **Source:** Synthesized from `JOURNEY.md`, `README.md`, and `docs/01-architecture.md`.
> **Not yet published to an issue tracker** — this repository has no remote and
> no issue tracker configured. Publish by creating the issue with this body and
> applying the `needs-triage` label once a tracker exists.

## Problem Statement

The owner needs secure remote access to private resources from untrusted
networks (café and campus Wi-Fi) but is unwilling to accept the trade-offs of
commercial VPNs: per-user subscriptions ($5–12/month), zero control over
servers and logs, and nothing to show for the money. The default alternatives
each fail on one core requirement — managed cloud VPNs are over-budget
(~$36/month), and a pure SaaS coordination product (Tailscale alone) proves
nothing about the owner's infrastructure skills. The owner also operates on a
student free account where every running resource spends limited credits that
must stretch across six planned portfolio projects, so near-zero cost is a hard
requirement, not a preference.

## Solution

A self-hosted, 100%-Terraform, dual-stack VPN server on a single Google Cloud
free-tier VM. **Tailscale** is the primary tunnel (auto-reconnecting, works
behind mobile CGNAT) and **WireGuard** runs as an auditable in-kernel backup on
the well-known UDP port. The solution is defense-in-depth (cloud firewall →
host firewall → key-only SSH → tunnel crypto), pay-when-you-use (ephemeral IP +
DuckDNS + wake-on-demand), fully observable (per-device activity logging with a
Grafana/Loki/Promtail stack), reproducible (crash-proof state, CI quality
gates), and validated by a test suite where every test maps to a decision or
incident from the build journey.

## User Stories

1. As a VPN owner, I want to connect from any untrusted network (café/campus), so that my traffic stays private.
2. As a VPN owner, I want the server to cost near zero per month, so that I can run it on a student free account without burning credits I need for other projects.
3. As a mobile user, I want the tunnel to reconnect automatically when the server's IP changes, so that I never have to manually toggle the VPN app.
4. As a mobile user behind carrier CGNAT, I want the tunnel to still work, so that incoming connections are possible without port forwarding.
5. As an admin, I want SSH allowed only from my own IP, so that scanner botnets can't reach the host.
6. As an admin, I want the unsafe configuration to be rejected by the infrastructure tooling, so that the mistake is unrepresentable in code.
7. As a VPN owner, I want per-device activity logs and dashboards, so that I can answer "what was this device doing and when" without any client-side install.
8. As a VPN owner, I want to wake the VM on demand from my phone, so that a stopped (cost-zero) VM comes up when I decide to use it.
9. As a VPN owner, I want to add or remove a client with one command, so that onboarding is fast and revocation is auditable.
10. As a VPN owner, I want a WireGuard backup path, so that the VPN still works if the Tailscale coordination service is unreachable.
11. As a reviewer, I want to reproduce the entire deployment from nothing, so that I can validate the project end-to-end without the original author.
12. As a developer, I want CI quality gates, so that the repository can't drift into an unbuildable or insecure state.
13. As a VPN owner, I want to be alerted if the VPN goes down, so that I can act before connectivity is needed.

## Implementation Decisions

### Modules

The system is decomposed into deep modules with stable contracts — each owns a
single concern and exposes a small, predictable interface:

1. **Network module** — owns the custom-mode VPC, the deliberately small /28
   subnet, Private Google Access, and the least-privilege firewall rule set
   (tunnel port, admin-only SSH, explicit deny-all with logging). Contract:
   inputs of region, subnet CIDR, admin IP CIDR, and tunnel port produce a
   complete, hardened network. Rejects `0.0.0.0/0` SSH by construction.
2. **VPN server module** — owns the free-tier e2-micro VM: Shielded VM,
   zero-scope service account, size-constrained boot disk, and an idempotent
   startup routine (marker-file guarded) that installs WireGuard, host
   hardening, the activity logger, and dynamic DNS. Contract: apply → a
   hardened, logged, DNS-tracked VPN server with no manual provisioning steps.
3. **Connectivity layer** — owns the dual-stack tunnels: WireGuard (`wg0`,
   per-peer keypairs plus preshared keys, server-side keepalive) as the backup
   and Tailscale (exit node, DERP fallback, automatic key exchange and IP
   tracking) as the primary path for mobile clients.
4. **Client lifecycle** — owns per-peer provisioning and revocation: one
   command adds a client with unique keys and emits a QR config; one command
   removes it. No peer config is hand-edited.
5. **Dynamic DNS and lifecycle management** — owns DuckDNS updates (systemd
   timer), the wake-on-demand Cloud Function (token-authenticated VM start),
   and the scheduled VPN health check (DNS + tunnel-port reachability feeding
   a custom metric and alert logs).
6. **Observability** — owns the activity logger (peer name mapping, CONNECT /
   DISCONNECT / traffic events) and the Grafana + Loki + Promtail stack behind
   an authenticated Nginx reverse proxy, with dashboards stored as code.
7. **State and delivery** — owns Terraform state in a versioned remote backend,
   the reusable modules, and the CI gates (format, validate, infrastructure
   security scan, shell lint).

### Technical Choices

- **WireGuard over OpenVPN:** ~4k lines vs ~70k (auditable, smaller attack
  surface), in-kernel since Linux 5.6, declarative ~10-line config. Accepted
  trade-off: UDP-only, fails where all UDP is blocked — mitigated by the
  Tailscale primary path.
- **Custom-mode VPC over auto-mode:** one subnet instead of ~40 regions of
  accidental attack surface and cost exposure.
- **Free-tier region (us-east1):** e2-micro compute is $0 there; any other
  region silently bills ~$6.11/month.
- **Ephemeral IP + DuckDNS + wake-on-demand:** a reserved IP bills ~$0.24/day
  while the VM is stopped; ephemeral + dynamic DNS + on-demand start makes a
  stopped VPN truly cost zero.
- **Tailscale pivot (dual-stack):** WireGuard alone cannot recover from server
  IP rotation on mobile — no coordination layer, mobile OS DNS caching, no
  NAT traversal, no health signaling. Tailscale adds the coordination server;
  WireGuard remains the zero-third-party backup. This is a documented path
  abandonment, not an oversight.
- **Auto-shutdown defaulted off:** on free-tier compute, nightly shutdown saves
  less than the reserved-IP cost it incurs; the schedule is wired and
  documented, ready to flip when the VM runs on billable compute.
- **Observability with a small footprint:** log shipping configured to fit the
  1 GB VM's memory budget; monitoring exposed only via an authenticated reverse
  proxy on the tunnel-facing port, restricted to the admin IP.
- **Terraform validation as invariant:** unsafe states (SSH open to the world)
  are rejected in code so the mistake cannot recur or be forked.
- **Secrets never in git or state:** keys and tokens stay on the encrypted
  disk, gitignored.

### ADR References

No formal ADR files exist in this repository. The de-facto decision record is
`JOURNEY.md`, which documents each decision with its rationale and trade-off:

- Requirement-driven technology selection (Day 1)
- Custom VPC and region choice (Day 2)
- SSH access control made unrepresentable in code (Day 3)
- e2-micro sizing validated by measurement, not folklore (Day 4)
- NAT keepalive for stateful middleboxes (Day 5)
- Auto-shutdown cost arithmetic (Day 6)
- Crash-proof state via remote backend (Day 11)
- DuckDNS + ephemeral IP + wake-on-demand (Day 12)
- ISP port blocking and the Tailscale pivot (Day 13–14)
- Monitoring stack and reboot-test results (Day 15)

Recommended next step: extract these into numbered ADRs if this project grows
past portfolio scope.

## Testing Decisions

Validation is test-first and incident-driven: the eight-suite test suite is the
primary proof that the system works, and every test is traceable to a specific
journey decision or failure. Tests run from any machine with the standard CLI
tooling and SSH access; results are captured as a single reproducible log.

- **Connectivity & tunnel health:** DNS resolution, tunnel reachability,
  Tailscale direct connect, health-check function.
- **Failover & resilience:** ephemeral IP rotation, IP-stable tailnet, keepalive,
  DNS propagation — proving IP changes don't break connectivity.
- **Security validation:** firewall rules, host firewall, intrusion prevention,
  auto-patching, tunnel encryption, Shielded VM — proving defense-in-depth is
  active, not just documented.
- **Performance & capacity:** latency, resource usage under load, throughput,
  disk I/O — proving the shared-core VM carries real traffic.
- **Operational validation:** activity logger, dynamic DNS updater, log
  rotation, auto-shutdown, startup idempotency.
- **Infrastructure & Terraform:** remote state, drift detection, client
  lifecycle, CI pipeline.
- **Cost & compliance:** free-tier eligibility, billing alerts, resource
  labeling and minimization.
- **Documentation & reproducibility:** completeness checks enabling a stranger
  to reproduce the project.

Known expected failures are documented rather than silently suppressed (GCP
blocks ICMP by default; host firewall state after a VM reset is re-verified
manually). Coverage gaps accepted for now: throughput tests need the
benchmarking tool installed, and the suite is not yet wired into CI.

## Out of Scope

- Multi-region or high-availability deployment — a single free-tier VM is the
  intended shape.
- Production-grade secrets management — keys stay on the encrypted disk;
  external secret storage is explicitly deferred.
- A self-hosted Tailscale control plane — the coordination service is a
  deliberately accepted third-party dependency.
- Multi-tenant or fleet-scale client support — target is 1–3 personal devices.
- Cloud NAT and internal-only VMs — Private Google Access is enabled for the
  future, but no internal resources are deployed today.
- Sustained multi-client throughput optimization — measured need is met; the
  documented upgrade path (larger machine type) is deferred until needed.
- Commercial VPN replacement at scale — this serves one owner's devices.

## Further Notes

- **Blocker for publication:** the repository has no remote and no issue
  tracker configured. This PRD is filed in-repo; create the issue and add the
  `needs-triage` label once a tracker exists, or wire one up as a follow-up.
- **Dependencies:** a Google Cloud project with billing and free-tier
  eligibility, a Tailscale account, a DuckDNS domain, and the standard CLI
  tooling (Terraform, gcloud, Docker on the VM).
- **Open question:** whether to extract `JOURNEY.md` decisions into formal ADRs
  before adding future features.
- **Natural next features** (currently tracked as backlog): per-device traffic
  dashboards from peer counters, CI-driven test execution, and automated
  benchmark tooling.
