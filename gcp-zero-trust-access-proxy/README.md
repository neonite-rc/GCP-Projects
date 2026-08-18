# GCP Zero Trust Access Proxy

[![Terraform CI](https://github.com/neonite-rc/gcp-vpn-server/actions/workflows/terraform.yml/badge.svg)](https://github.com/neonite-rc/gcp-vpn-server/actions/workflows/terraform.yml)

> Originally built as a self-hosted VPN on Google Cloud. After 17 days of iteration the architecture evolved into a Zero Trust Network Access proxy: identity-aware, per-device access with WireGuard + Tailscale coordination, ephemeral IPs, and pay-per-use lifecycle.

Self-hosted ZTNA on GCP — WireGuard + Tailscale dual-stack, custom VPC, full security hardening, reproducible Terraform. ~$51.68/mo for 10 global locations.

## What & Why

**Problem:** Commercial VPNs are identity-free, always-on, and charge per user. A student free-tier account needs secure remote access to private resources from untrusted networks with zero trust principles: verify every connection, least privilege, and cost optimization.

**Solution:** A Zero Trust Access Proxy that authenticates devices via Tailscale coordination, routes traffic through per-region WireGuard exit nodes, and only “exists” when needed. VM stops nightly, wakes on demand, costs $0 when idle.

Started as VPN research. Tailscale’s coordination server solved WireGuard’s mobile DNS-caching and IP rotation issues, turning a VPN into a true ZTNA design: device posture, dynamic routing, and audit logging without manual reconnection.

**Business decisions:** Why GCP over AWS, why Cloud Run/Functions over GKE, and why these 10 regions were chosen are documented in [docs/JOURNEY.md](docs/JOURNEY.md) under *Business & Platform Rationale* — cost-first, serverless control plane vs VM data plane, and free-tier constraints.

## Architecture

![Architecture](docs/diagrams/architecture.png)


10 access nodes across 4 continents. Clients connect via Tailscale primary — auto-reconnect, IP change tracking, DERP fallback — with WireGuard as backup. SSH locked to single admin IP via Terraform validation.

Details: [docs/01-architecture.md](docs/01-architecture.md)

## Quick Start

```bash
git clone <repo>
cd gcp-zero-trust-access-proxy/terraform
cp terraform.tfvars.example terraform.tfvars   # fill project, admin IP, SSH key
terraform init
terraform plan
terraform apply
```

Add a device:
```bash
sudo /usr/local/sbin/add-client.sh my-phone
# prints WireGuard config + QR code
```

Full reproducibility: `terraform destroy && terraform apply` ~4 minutes to working proxy.

## Stack & Design Decisions

| Layer | Choice | Why |
|-------|--------|-----|
| Cloud | GCP e2-micro, Shielded VM, custom-mode VPC, Cloud Firewall, ephemeral IP | Free-tier eligible in us-east1; custom VPC avoids auto-mode bloat |
| Access | WireGuard + Tailscale | WireGuard in-kernel ~150 Mbps; Tailscale adds coordination for ZTNA |
| Monitoring | Grafana + Loki + Promtail, Nginx basic auth | Log-centric observability, dashboards-as-code |
| Hardening | Debian 12, UFW, fail2ban, unattended-upgrades, SSH key-only | Defense in depth, structural safety |
| IaC | Terraform >=1.5, GCS backend, custom modules | Reproducible, crash-proof state |
| DNS | DuckDNS + 1-min updater | Tracks ephemeral IPs, $0 when stopped |
| Serverless | Cloud Functions wake-vpn / vpn-health | Pay-per-use lifecycle |

## Results

- 10 global nodes, 2 free-tier, $51.68/mo total
- Zero Trust: device identity via Tailscale, per-peer WireGuard keys, audit logs
- Auto-reconnect after IP rotation, CGNAT traversal via DERP
- 38-test validation suite, 27 pass, CI enforced `terraform fmt/validate` + Trivy

Limitations: WireGuard mobile still requires manual toggle if used without Tailscale; UDP-only; e2-micro CPU bursting.

## Project Structure

```
terraform/          IaC modules: network, vpn-server, cloud-function, dns
src/scripts/        add-client, wg-activity-log, DuckDNS updater
src/functions/      wake-vpn, vpn-health Cloud Functions
src/monitoring/     Grafana dashboards-as-code, Loki, Promtail
docs/               JOURNEY.md, architecture, cost, security, troubleshooting
assets/screenshots/ demo screenshots
vpn-test-suite.sh   end-to-end validation
```

## Further Reading

- [docs/JOURNEY.md](docs/JOURNEY.md) — 17-day decision log: VPN → ZTNA pivot
- [docs/01-architecture.md](docs/01-architecture.md)
- [docs/02-cost-analysis.md](docs/02-cost-analysis.md)
- [docs/03-security.md](docs/03-security.md)
- [docs/05-troubleshooting.md](docs/05-troubleshooting.md)

License: CC0 1.0 Universal
---
*Business rationale for platform choices is documented in each project's JOURNEY.md.*
