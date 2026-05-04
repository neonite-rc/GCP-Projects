# GCP VPN Server (WireGuard)

[![Terraform CI](https://github.com/neonite-rc/gcp-vpn-server/actions/workflows/terraform.yml/badge.svg)](https://github.com/neonite-rc/gcp-vpn-server/actions/workflows/terraform.yml)

Self-hosted WireGuard VPN on Google Cloud — custom VPC, full security
hardening, reproducible Terraform, pay-per-use lifecycle. Built on the
student free-tier so it costs ~$0 when idle.

## What & Why

**Problem:** Commercial VPNs are identity-free, always-on, and charge per
user. A student free-tier account needs secure remote access to private
resources from untrusted networks (café/campus Wi-Fi) without giving a
third party my keys or logs.

**Solution:** A self-hosted WireGuard VPN on GCP — in-kernel ~150 Mbps,
auditable ~4k lines of code, per-peer keys I control, and a VM that stops
nightly and wakes on demand so it costs $0 when idle.

## Architecture

```
                 Cloud DNS (weighted A records)
                /          |           \
         us-east1     asia-south1   europe-west1  ... (regions)
        (FREE $0)     (Mumbai)      (Belgium)
         e2-micro VM  e2-micro VM   e2-micro VM
         wg0          wg0           wg0
         10.0.0.0/28  10.0.2.0/28   10.0.5.0/28
```

Clients connect via WireGuard to per-region exit nodes. SSH is locked to a
single admin IP via a Terraform validation rule.

## Quick Start

```bash
git clone https://github.com/neonite-rc/gcp-vpn-server.git
cd gcp-vpn-server/terraform
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

Full reproducibility: `terraform destroy && terraform apply` ~4 minutes to
a working VPN.

## Stack & Design Decisions

| Layer | Choice | Why |
|-------|--------|-----|
| Cloud | GCP e2-micro, Shielded VM, custom-mode VPC, Cloud Firewall, ephemeral IP | Free-tier eligible in us-east1; custom VPC avoids auto-mode bloat |
| VPN | WireGuard | ~4k LoC, in-kernel, per-peer keys, $0 on free tier |
| Monitoring | Grafana + Loki + Promtail, Nginx basic auth | Log-centric observability, dashboards-as-code |
| Hardening | Debian 12, UFW, fail2ban, unattended-upgrades, SSH key-only | Defense in depth, structural safety |
| IaC | Terraform >=1.5, GCS backend, custom modules | Reproducible, crash-proof state |
| DNS | DuckDNS + 1-min updater | Tracks ephemeral IPs, $0 when stopped |
| Serverless | Cloud Functions wake-vpn / vpn-health | Pay-per-use lifecycle |

## Results

- Self-hosted WireGuard VPN, ~150 Mbps on a shared-core e2-micro
- Zero third-party trust: my keys, my logs
- Auto-reconnect after IP rotation via DuckDNS + persistent-keepalive
- 38-test validation suite, CI enforced `terraform fmt/validate` + Trivy

Limitations: UDP-only; e2-micro CPU bursting; manual client toggle after
some IP rotations (being improved).

## Project Structure

```
terraform/          IaC modules: network, vpn-server, cloud-function, dns
src/scripts/        add-client, wg-activity-log, DuckDNS updater
src/functions/      wake-vpn, vpn-health Cloud Functions
src/monitoring/     Grafana dashboards-as-code, Loki, Promtail
docs/               JOURNEY.md, architecture, cost, security, troubleshooting
vpn-test-suite.sh   end-to-end validation
```

## Further Reading

- [docs/JOURNEY.md](docs/JOURNEY.md) — day-by-day decision log
- [docs/01-architecture.md](docs/01-architecture.md)
- [docs/02-cost-analysis.md](docs/02-cost-analysis.md)
- [docs/03-security.md](docs/03-security.md)
- [docs/05-troubleshooting.md](docs/05-troubleshooting.md)

License: CC0 1.0 Universal
