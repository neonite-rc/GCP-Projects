# PENDING.md — gcp-vpn-server

> Last updated: 2026-08-17
> Items requiring manual action (cannot be automated).

---

## 🔴 Security — Rotate Passwords

The `graphana-creds.md` file has been deleted from the repo. Before pushing, rotate both compromised passwords:

```bash
# 1. Grafana admin
docker exec -it grafana grafana-cli admin reset-admin-password <new-password>

# 2. Gmail
# → accounts.google.com → Security → Change password
```

---

## 🟡 Activation Required

### 1. Tailscale auth (on each server)
After `terraform apply`, SSH into each server and authenticate Tailscale:
```bash
ssh admin@<server-ip>
sudo tailscale up
# Follow the auth URL printed to console
```
Or set `ts-authkey` in Terraform metadata for auto-auth.

### 2. Set VPN endpoint IPs for client scripts
The client scripts (`vpn-connect.sh`, `vpn-random.sh`) need server IPs.
Set via env var or let them auto-discover from Terraform output:
```bash
export VPN_ENDPOINTS="us-east1=34.x.x.x,us-west1=35.x.x.x,..."
# OR run from the repo directory (auto-discovers from `terraform output`)
```

---

## 🟡 Demo & Portfolio Evidence

### 3. Screen recording (demo video)
- **What:** 2-min screen recording uploaded to YouTube (unlisted), linked in README.
- **Suggested flow:** Tailscale connect → traffic routed → Grafana dashboard → `terraform destroy`.
- **Action:** Record with OBS/Loom, upload to YouTube (unlisted), replace `[2-min screen recording — link placeholder]` in README.

### 4. Architecture diagram image
- **What:** PNG/SVG diagram in `assets/` (draw.io or Excalidraw).
- **Action:** Export a proper diagram to `assets/architecture.png` and reference it in the README.

---

## ✅ Completed (2026-08-17)

- [x] Deleted `graphana-creds.md` (plaintext credentials)
- [x] Fixed GitHub badge placeholder → `neonite-rc`
- [x] Multi-region VPN: 10 servers across 4 continents (for_each refactor)
- [x] `add-client.sh` updated with `--region local|all|<key>` flag
- [x] `vpn-health` Cloud Function probes all regions, writes per-instance metrics
- [x] Tailscale auto-install + auto-start in startup.sh
- [x] `vpn-endpoints.sh` — server discovery helper
- [x] `vpn-connect.sh` — interactive region selector (menu + WireGuard/Tailscale)
- [x] `vpn-random.sh` — random/fastest server picker
- [x] `docs/04-scaling.md` updated with 10-region section
- [x] `docs/TODO.md` cleaned up
- [x] Test suite docs updated — skipped tests documented
- [x] `terraform fmt` + `terraform validate` pass
