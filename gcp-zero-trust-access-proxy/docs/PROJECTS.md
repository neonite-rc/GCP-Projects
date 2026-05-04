# GCP Portfolio Projects

> Overview of all GCP projects in my portfolio account.
> Updated: 2026-08-10

---

## Active Projects

| Project ID | Name | Purpose | Monthly Cost | Status |
|-----------|------|---------|-------------|--------|
| `portfolio-vpn-2026` | Portfolio VPN Server | Self-hosted WireGuard VPN on GCP free tier | ~$0 (e2-micro in us-east1) | ACTIVE |

### portfolio-vpn-2026

- **What:** WireGuard VPN server — custom VPC, Shielded VM, UFW + fail2ban hardening
- **Stack:** Terraform, Debian 12, WireGuard, Bash scripts, GitHub Actions CI
- **Infra:** e2-micro in us-east1 (free tier), ephemeral IP tracked by DuckDNS, /28 subnet
- **Cost:** $0/mo compute (free tier), ~$0.02/day egress when active
- **Repo:** `gcp-vpn-server/`
- **Key docs:** [README.md](../README.md), [JOURNEY.md](../JOURNEY.md), [TODO.md](TODO.md)

---

## Deleted Projects (recoverable for limited window)

| Project | Original Name | Deleted |
|---------|---------------|---------|
| `[deleted-project]` | Default Gemini Project | 2026-08-08 |
| `[deleted-project]` | Video Analysis | 2026-08-08 |
| `[deleted-project]` | Job Scraper | 2026-08-08 |

Recover with: `gcloud projects undelete <PROJECT_ID>`

---

## Planned Projects (from [TODO.md](TODO.md))

Additional GCP portfolio projects to deploy — 3 more project ideas needed to fill the portfolio. Candidates discussed:

- LangChain client app (replaces deleted `gen-lang-client`)
- Job scraper (replaces deleted `job-scrapper`)
- 1 more TBD

---

## Account-Level Setup

| Item | Status |
|------|--------|
| Billing account | `[billing-account-id]` |
| Budget alerts | ₹900/month at 50%/90%/100% (console) |
| Free tier | e2-micro in us-east1, 750 hrs/mo |
| gcloud config project | `portfolio-vpn-2026` |
