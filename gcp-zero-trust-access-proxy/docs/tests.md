run test script

## Tests to Add (Based on Your Assets)

### Documentation Integrity Tests
| Test | What It Proves | File to Check |
|---|---|---|
| `CREDENTIALS.md` is gitignored | No secrets leak in version control | `.gitignore` + `keys/CREDENTIALS.md` |
| `JOURNEY.md` references match live state | Your narrative is current, not stale | `JOURNEY.md` vs `gcloud compute instances list` |
| Architecture doc matches Terraform | Design doc and code don't diverge | `docs/01-architecture.md` vs `terraform show` |
| Cost analysis is dated | Shows you revisited costs after changes | `docs/02-cost-analysis.md` timestamp |

### Script Validation Tests
| Test | What It Proves | Script to Run |
|---|---|---|
| `startup.sh` is idempotent | Re-running doesn't break things | `ssh … sudo bash /usr/local/sbin/startup.sh` (marker guard test) |
| `add-client.sh` generates valid config | Client configs are syntactically correct | Parse output with `wg pubkey` |
| `remove-client.sh` cleans up state | No orphaned peers after removal | `wg show` before/after |
| `duckdns-update.sh` handles API failure | Graceful degradation if DuckDNS is down | Mock 500 response |

### Cloud Function Tests
| Test | What It Proves | Endpoint to Hit |
|---|---|---|
| `wake-vpn` rejects bad tokens | Auth actually works, not just "has auth" | `curl …?token=wrong` → expect 403 |
| `vpn-health` metric is writable | Custom metric permissions are correct | Check `custom.googleapis.com/vpn/health` in Monitoring |
| `vpn-status` page loads without auth | Public status page is actually public | `curl -I …/vpn-status` → 200 |

---

## Refined Test Script (Updated for Your Paths)

Key changes from v1:
- **Suite 5.6** — `CREDENTIALS.md` gitignore check
- **Suite 5.7** — `JOURNEY.md` freshness (checks if documented IP matches live IP)
- **Suite 6.5** — `startup.sh` idempotency test (re-run marker guard)
- **Suite 6.6** — `add-client.sh` config validation (syntax check generated `.conf`)
- **Suite 1.9** — `wake-vpn` auth rejection test (bad token → 403)
- **Suite 1.10** — `vpn-status` page availability
- **Suite 7.5** — Architecture doc vs Terraform drift (subnet CIDR match)

---

## The "Reviewer Walkthrough" Script

For maximum portfolio impact, create a second script that **narrates** the test run:

```bash
#!/bin/bash
# reviewer-demo.sh — A guided tour for portfolio reviewers
# Run this and pipe to asciinema for a recorded demo

echo "=== GCP VPN Portfolio Demo ==="
echo "Project: portfolio-vpn-2026"
echo ""

echo "[1/5] Infrastructure state (Terraform GCS backend)..."
terraform show | head -20

echo "[2/5] Live VPN health..."
curl -s https://us-east1-portfolio-vpn-2026.cloudfunctions.net/vpn-health | jq .

echo "[3/5] Activity log (last 3 events)..."
ssh debian@gcp-vpn.duckdns.org "sudo tail -3 /var/log/wg-activity.log"

echo "[4/5] Cost status (free tier check)..."
gcloud compute instances describe wireguard-vpn --zone=us-east1-b --format='value(machineType,status)'

echo "[5/5] Full validation suite..."
./vpn-test-suite.sh --full
```

Record this with [asciinema](https://asciinema.org/) and embed the cast in your README. A 2-minute video of you running tests beats 20 paragraphs of description.

---

## What Your README Should Look Like

Given your asset structure, here's the README section that ties it all together:

```markdown
## 🧪 Validation & Testing

Every component is testable. Run the full suite:

```bash
./scripts/vpn-test-suite.sh
```

| Suite | Tests | What It Validates |
|-------|-------|-------------------|
| Connectivity | 10 | Tunnels, DNS, health checks, auth rejection |
| Failover | 4 | IP rotation, auto-reconnect, keepalive, propagation |
| Security | 6 | Firewall, UFW, fail2ban, encryption, Shielded VM, patches |
| Performance | 5 | Latency, throughput, CPU, memory, disk I/O |
| Operations | 7 | Logging, timers, rotation, shutdown, idempotency, docs |
| Infrastructure | 6 | GCS state, drift, client scripts, CI, architecture match |
| Cost | 5 | Free tier, billing alerts, labels, no waste |
| Documentation | 4 | README, diagram, troubleshooting, credential safety |

**See [JOURNEY.md](../JOURNEY.md)** for the 15-day decision log — every test maps to a documented bug or trade-off.

**See [02-cost-analysis.md](02-cost-analysis.md)** for the $0/mo breakdown.
```

---

## Final Checklist Before You Call This "Done"

- [ ] Run `./vpn-test-suite.sh` from a **different machine** (your Fedora backup) — validates portability
- [ ] Run it after a `terraform destroy && terraform apply` — validates the 4-minute claim
- [ ] Record the `reviewer-demo.sh` with asciinema — 2 min video > 20 paragraphs
- [ ] Verify `keys/CREDENTIALS.md` is in `.gitignore` and not committed
- [ ] Check that `JOURNEY.md` Day 15 matches today's live state (IP, keys, ports)
- [ ] Add a "Known Limitations" section to README — e.g., "WireGuard mobile clients require manual toggle after IP rotation (see Day 13). Tailscale handles this automatically."

Your project already has the depth. These tests make that depth **discoverable** to someone reviewing your repo in 5 minutes.
