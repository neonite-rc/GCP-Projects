# Security

Defense in depth: four independent layers must all fail before compromise.

## Layer 1 — Cloud firewall (network edge)

- Only UDP 51820 is open to the world. WireGuard is silent to unauthenticated
  probes (no handshake response without a valid key), so port scans see nothing.
- SSH (TCP 22) restricted to a single admin IP `/32`. Terraform **rejects**
  `0.0.0.0/0` for `admin_ip_cidr` via a validation block — a lesson learned
  the hard way (see JOURNEY.md Day 3).
- Explicit deny-all rule at priority 65534 with logging enabled: blocked
  attempts are visible in Cloud Logging.

## Layer 2 — Host firewall (UFW)

- Default deny incoming; only 22/tcp and 51820/udp allowed.
- Protects even if a cloud firewall rule is fat-fingered later.

## Layer 3 — SSH hardening

- `PasswordAuthentication no`, `PermitRootLogin no` — key-based auth only.
- `block-project-ssh-keys = true` — project-wide SSH keys are ignored;
  only the key provisioned via Terraform works.
- fail2ban: 3 failed attempts = 1-hour ban.

## Layer 4 — WireGuard cryptography

- Curve25519 key exchange, ChaCha20-Poly1305 AEAD, BLAKE2s hashing —
  a modern, small (~4k LoC) codebase vs OpenVPN's ~70k.
- Per-client keypairs: revoking one client (remove-client.sh) never
  affects others.
- Preshared key per peer adds a symmetric layer (post-quantum hedge).

## Platform hardening

- **Shielded VM**: Secure Boot, vTPM, integrity monitoring — detects
  boot-level tampering.
- **Dedicated service account with zero roles and zero scopes**: a
  compromised VM cannot call any GCP API (avoids the default compute SA,
  which has broad project access).
- **VPC flow logs** on the subnet (10% sampling to stay in the logging
  free tier) — network forensics if anything ever goes wrong.
- **Unattended-upgrades**: security patches auto-applied daily.

## Supply-chain / code integrity

- CI runs **Trivy IaC misconfiguration scanning** (MEDIUM+ fails the build),
  `terraform fmt/validate`, and ShellCheck on every push.
- Accepted risks are suppressed **inline with written justification**
  (`#trivy:ignore` next to the resource), never globally — the reviewer
  sees the reasoning at the exact line it applies to.
- Client names in admin scripts are regex-validated before being used in
  file paths.

## Secrets handling

- Server/client private keys generated **on the VM** (umask 077), never
  stored in Terraform state or Git.
- `terraform.tfvars` (contains admin IP, SSH public key) is gitignored.

## Known residual risks

| Risk | Mitigation status |
|------|-------------------|
| Admin IP changes (dynamic home IP) | Re-run `terraform apply` with new IP |
| VM kernel 0-day | Unattended-upgrades; small attack surface |
| Stolen client device | Revoke peer with remove-client.sh |
| DDoS on UDP 51820 | Accepted for demo; production: Cloud Armor + LB |
