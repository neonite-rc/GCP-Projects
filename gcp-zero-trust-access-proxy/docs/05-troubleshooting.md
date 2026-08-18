# Troubleshooting

Real problems hit during the build, and how they were fixed.

## 1. Client connects but no internet

**Symptom:** Handshake succeeds (`wg show` shows recent handshake), but no
traffic flows.

**Investigation:** `tcpdump -i wg0` showed packets arriving; `tcpdump -i ens4`
showed nothing leaving.

**Root cause(s):** Two separate switches must both be on:
1. Kernel: `net.ipv4.ip_forward = 1` (sysctl)
2. GCP: `can_ip_forward = true` on the instance — **this cannot be changed
   after VM creation**; it forces a recreate.

**Fix:** Both set in Terraform/startup script from the start.

## 2. Handshake fails entirely

**Checklist that solved it:**
- Firewall rule targets the `wireguard` **network tag** — VM missing the tag
  receives nothing.
- Client `Endpoint` must use the **static external IP**, not the ephemeral
  one printed at first boot (this is why Terraform reserves
  `google_compute_address`).
- Server public key mismatch after VM recreate: keys are generated on-VM, so
  a rebuilt VM = new keys = every client config must be reissued.

## 3. SSH lockout after tightening firewall

**Symptom:** Changed `admin_ip_cidr` to home IP, then couldn't SSH from
a coffee shop. Working as intended, but briefly alarming.

**Recovery options documented:**
- Update `admin_ip_cidr` in tfvars, `terraform apply` (30s).
- Emergency: GCP Console serial port access (enabled by default).

**Lesson:** Dynamic home IPs mean this rule needs occasional updates —
acceptable trade-off vs open SSH.

## 4. Clients behind NAT drop after idle

**Symptom:** Phone client works, then silently dies after ~2 min idle.

**Root cause:** Home router NAT table expired the UDP mapping; the server
couldn't initiate packets to the client anymore.

**Fix:** `PersistentKeepalive = 25` on the client side. 25s is below
typical NAT timeouts (30–60s).

## 5. UFW blocked forwarded traffic

**Symptom:** After enabling UFW, clients lost internet again even with
iptables NAT rules present.

**Root cause:** UFW's default `FORWARD` policy is DROP; it sits in front
of the wg-quick PostUp rules.

**Fix:** `ufw route allow in on wg0` (and UFW default forward policy
handled in startup.sh).

## 6. Client key rotation (lost phone, compromised key, periodic refresh)

WireGuard keys are static — there's no built-in expiry. If a device is
lost, stolen, or you just want to rotate, follow this procedure.

### Option A: Revoke + re-add (recommended for lost/stolen devices)

```bash
# 1. SSH into the server (use the DuckDNS hostname — the IP is ephemeral)
ssh -i ~/.ssh/gcp-vpn-admin_ed25519 admin@gcp-vpn.duckdns.org

# 2. Remove the old peer (deletes config + revokes key from wg0)
sudo /etc/wireguard/remove-client.sh <client-name>

# 3. Re-add with a NEW name (generates fresh keypair + PSK)
sudo /etc/wireguard/add-client.sh <client-name-v2>

# 4. On the new device: scan the QR code or copy the config file
cat /etc/wireguard/clients/<client-name-v2>.conf
# or: sudo qrencode -t ansiutf8 < /etc/wireguard/clients/<client-name-v2>.conf
```

**Why a new name?** The add-client script checks `$CLIENT_DIR/$NAME.conf`
and refuses to overwrite. Using a new name avoids manual cleanup. The old
name can be reused after deleting `$CLIENT_DIR/<old-name>.conf`.

### Option B: Rotate without renaming (same device, key refresh)

```bash
# 1. Remove old peer
sudo /etc/wireguard/remove-client.sh phone1

# 2. Re-add with same name (old .conf is now deleted, so it works)
sudo /etc/wireguard/add-client.sh phone1

# 3. Update the WireGuard app on the device with the new config
```

### What happens on removal

- `remove-client.sh` deletes the `[Peer]` block from `wg0.conf`
- Deletes `/etc/wireguard/clients/<name>.conf`
- Runs `wg syncconf` — the peer is immediately kicked (no restart needed)
- Next `wg-activity-log.sh` run cleans up the stale state file

### Important: VM recreate = all clients orphaned

Server keys are generated on first boot (`/etc/wireguard/server_*`). A
`terraform destroy && terraform apply` creates a new VM with new keys,
making every existing client config invalid. This is by design for a demo
project — in production you'd store keys in Secret Manager.

---

## Diagnostic commands

```bash
sudo wg show                 # handshake age, transfer counters per peer
sudo systemctl status wg-quick@wg0
sudo journalctl -u wg-quick@wg0 -e
sudo tcpdump -ni any udp port 51820   # is traffic arriving at all?
sudo iptables -t nat -L POSTROUTING -v -n
sysctl net.ipv4.ip_forward
```
