# Cost Analysis

## Budget context: student free account

This runs on a GCP free/student account: $300 trial credits shared across
a 7-project portfolio, plus the always-free tier. Guardrails in place
**before** any resource was created:

- Billing alerts at $50 / $100 / $150 / $200 / $250
- Budget for this project: **≤ $3 total** (came in at $2.46)
- Rule: prefer free-tier-eligible SKUs; anything billable needs a written
  justification in JOURNEY.md

## Actual spend (2-month portfolio window)

| Component | Specs | List Price/mo | My Usage | Cost |
|-----------|-------|---------------|----------|------|
| Compute (e2-micro) | 2 vCPU, 1 GB | $6.11 | 60 hrs (free tier) | $0.46 |
| Boot Disk | 10 GB Standard PD | $0.40 | 2 months | $0.80 |
| Network Egress | ~10 GB | $1.20 | 2 months | $1.20 |
| **TOTAL** | | | | **$2.46** |

## Free tier leverage

- **720 hrs/mo of e2-micro** in us-east1/us-west1/us-central1 is free —
  the VM itself costs $0 while it runs there.
- 30 GB standard PD is also free-tier eligible; the 10 GB boot disk fits.
- What actually costs money: **egress** (~$0.12/GB to internet) and the
  **static IP when the VM is stopped** ($0.01/hr idle).

## Optimizations applied

| Decision | Savings |
|----------|---------|
| us-east1 region (free-tier eligible) | $6.11/mo compute |
| e2-micro vs e2-small | $6+/mo |
| 10 GB standard PD vs 50 GB SSD | ~$8/mo |
| Custom VPC vs auto-mode (single subnet) | avoids multi-region sprawl |
| Self-hosted WireGuard vs Cloud VPN | $36/mo (Cloud VPN = $0.05/hr/tunnel) |
| vs commercial VPN (3 users @ $12/mo) | $36/mo |

## Cost traps documented

1. **Static IP on stopped VM** — billed ~$7.30/mo when unattached/idle.
   Mitigation: `terraform destroy` when not in use.
2. **Egress** — the only real variable cost. Heavy streaming through the
   VPN would dominate the bill.
3. **Auto-mode VPC** — subnets in ~40 regions; any accidental resource in
   another region bills there.
4. **Auto-shutdown that costs money** — Terraform includes an optional
   nightly stop schedule (`enable_auto_shutdown`). It defaults **off**
   because on the free tier a stopped VM makes its static IP billable
   (~$0.24/day), more than the $0 compute it saves. Enable it only when
   running on billable compute. Full math in JOURNEY.md Day 6.

## At scale (1000 users)

- e2-micro saturates ~150 Mbps; 1000 users need e2-standard-4 (~$97/mo)
  or a Managed Instance Group behind a UDP load balancer.
- At that point compare with Cloud VPN ($36/mo/tunnel) or IAP — see
  [04-scaling.md](04-scaling.md).
