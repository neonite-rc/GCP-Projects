# GCP Portfolio Index

> Central index for all Google Cloud projects in this portfolio.
> Updated: 2026-08-18

## Active Projects

| Project | Repo | Purpose | Stack | Cost/mo | Status |
|---------|------|---------|-------|---------|--------|
| Zero Trust Access Proxy | [zero-trust-access-proxy](.) | Self-hosted ZTNA with WireGuard + Tailscale, 10 global nodes, pay-per-use | Terraform, GCP, WireGuard, Tailscale, Grafana/Loki | ~$51.68 | Active |

### Zero Trust Access Proxy

- **What:** Originally designed as VPN, evolved into Zero Trust Network Access proxy with device identity, auto-reconnect, and ephemeral IPs.
- **Key docs:** [README.md](README.md), [docs/JOURNEY.md](docs/JOURNEY.md)
- **Reproducibility:** `terraform destroy && terraform apply` ~4 min

## Planned Projects

| Project | Purpose | Target Stack | Status |
|---------|---------|--------------|--------|
| _TBD_ | _Description_ | _Stack_ | Planned |

## Account Overview

- Billing alerts: configured
- Free tier usage: e2-micro us-east1/us-west1
- State backend: GCS with versioning

## How to add a project

1. Create project folder under `projects/<name>/`
2. Add entry to Active Projects table above
3. Ensure README follows portfolio template: What & Why, Quick Start, Stack, Results
