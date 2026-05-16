# Current Architecture

## Overview

Multi-region VPN service with 4 GCP servers. Dashboard runs on the primary server, generates WireGuard QR codes for phone switching.

## Servers

```
┌─────────────────────────────────────────────────────────┐
│                    GCP Project                           │
│                 portfolio-vpn-2026                       │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  us-east1    │  │  us-west1    │  │ asia-northeast│  │
│  │  Primary     │  │  Oregon      │  │  Tokyo        │  │
│  │              │  │              │  │              │  │
│  │ WireGuard    │  │ WireGuard    │  │ WireGuard    │  │
│  │ Tailscale    │  │ Tailscale    │  │ Tailscale    │  │
│  │ Dashboard    │  │              │  │              │  │
│  │ Port 8080    │  │              │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                         │
│  ┌──────────────┐                                      │
│  │ europe-west2 │                                      │
│  │ London       │                                      │
│  │              │                                      │
│  │ WireGuard    │                                      │
│  │ Tailscale    │                                      │
│  └──────────────┘                                      │
└─────────────────────────────────────────────────────────┘
```

## How It Works

### Phone Connection (WireGuard)
```
Phone (WireGuard app) ──QR scan──> Server WireGuard tunnel
                                    │
                                    ├─ us-east1:  10.200.200.2
                                    ├─ us-west1:  10.200.1.2
                                    ├─ asia-ne1:  10.200.8.2
                                    └─ europe-w2: 10.200.7.2
```

1. Open dashboard at `http://104.196.183.161:8080`
2. Tap a server → QR code appears
3. Open WireGuard app → `+` → Scan from QR code
4. Enable new tunnel, disable old one
5. Traffic now routes through that region

### Server Management (Tailscale)
```
Servers communicate via Tailscale mesh:
  100.112.117.1  wireguard-vpn (us-east1)
  100.99.149.53  wireguard-vpn-w2 (us-west1)
  100.95.2.34    wireguard-vpn-tokyo (asia-northeast1)
  100.121.90.47  wireguard-vpn-london (europe-west2)
```

### Dashboard Features
- Live Tailscale status (all 4 servers)
- Public IP display + "Verify" button (freeip.me)
- QR code per server (WireGuard format)
- Download `.conf` file option
- Auto-refreshes every 3 seconds

## Network Layout

```
Phone ──WireGuard──> GCP Server ──> Internet
                      │
                      ├── us-east1 (primary, always on)
                      ├── us-west1 (always on)
                      ├── asia-northeast1 (always on)
                      └── europe-west2 (always on)

Laptop ──Tailscale──> GCP Server (for dashboard access)
```

## Access Points

| Service | URL | Access |
|---------|-----|--------|
| Dashboard | `http://104.196.183.161:8080` | Public (GCP firewall) |
| Dashboard (Tailscale) | `http://100.112.117.1:8080` | Tailscale only |
| SSH | `ssh admin@<server-ip>` | Restricted to `49.37.112.107/32` |
| WireGuard | `<server-ip>:51820/UDP` | Public |

## Firewall Rules

| Rule | Port | Source | Target |
|------|------|--------|--------|
| SSH | 22/tcp | `49.37.112.107/32` | `wireguard` tag |
| WireGuard | 51820/UDP | `0.0.0.0/0` | `wireguard` tag |
| Dashboard | 8080/tcp | `0.0.0.0/0` | `vpn-exit-node` tag |

## Costs

- 4x e2-micro instances (us-east1 + us-west1 = free tier eligible)
- Asia + Europe regions incur charges (~$5-10/month total)
- No Cloud Functions currently deployed (removed by terraform)

## Limitations

1. **Phone switching requires QR scan** — not one-tap
2. **Dashboard runs on server** — exposed to internet
3. **No latency-based switching** — user picks manually
4. **WireGuard configs hardcoded** — adding servers requires code change
5. **Tailscale can't control phone's exit node** — phone must switch manually
