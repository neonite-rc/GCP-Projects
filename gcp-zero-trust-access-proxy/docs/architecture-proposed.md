# Proposed Architecture

## Overview

Clean Tailscale-based VPN dashboard. Runs locally on the laptop, controls the local Tailscale client directly. No WireGuard QR codes — pure Tailscale switching with one-tap.

## Architecture

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
│  │ (exit node)  │  │ (exit node)  │  │ (exit node)  │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                         │
│  ┌──────────────┐                                      │
│  │ europe-west2 │                                      │
│  │ London       │                                      │
│  │              │                                      │
│  │ WireGuard    │                                      │
│  │ Tailscale    │                                      │
│  │ (exit node)  │                                      │
│  └──────────────┘                                      │
└─────────────────────────────────────────────────────────┘
                              │
                    Tailscale mesh
                              │
┌─────────────────────────────┼───────────────────────────┐
│                     Your Devices                        │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Laptop     │  │   Phone      │  │   Tablet     │  │
│  │              │  │              │  │              │  │
│  │ Tailscale    │  │ Tailscale    │  │ Tailscale    │  │
│  │ Dashboard    │  │              │  │              │  │
│  │ (localhost)  │  │              │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## How It Works

### Laptop Connection (Dashboard)
```
Laptop ──Tailscale──> GCP Server ──> Internet
  │
  └── Dashboard at localhost:7979
       │
       └── tailscale set --exit-node=<hostname>
            │
            └── Laptop traffic routes through chosen server
```

1. Dashboard runs on laptop at `127.0.0.1:7979`
2. Click "Fastest" or pick a server
3. Dashboard runs `tailscale set --exit-node=<hostname>` locally
4. Laptop traffic now routes through that GCP server
5. Click "Disconnect" to stop

### Phone Connection (Tailscale App)
```
Phone ──Tailscale app──> GCP Server ──> Internet
  │
  └── Open Tailscale → tap server → "Use as exit node"
```

1. Open Tailscale app on phone
2. Tap `...` next to desired server
3. Enable "Use as exit node"
4. Done — phone traffic routes through that server

### Dashboard Features
- **Fastest** — pings all nodes with fping, connects to lowest latency
- **Random** — picks a random online node
- **Connect** — one-tap to any specific server
- **Disconnect** — clears exit node
- **Last command** — shows exact tailscale command executed
- **Light/dark theme** — auto-detects system preference
- **Auto-refresh** — every 15 seconds

## Key Differences from Current

| Aspect | Current | Proposed |
|--------|---------|----------|
| Dashboard location | Server (0.0.0.0:8080) | Laptop (127.0.0.1:7979) |
| Switching method | WireGuard QR codes | Tailscale CLI |
| Phone control | QR scan required | Tailscale app (manual) |
| Laptop control | Not supported | One-tap via dashboard |
| Latency testing | None | fping-based |
| UI | Dark theme only | Light/dark auto |
| Security | Exposed to internet | Localhost only |
| Dependencies | qrencode, WireGuard | tailscale, fping |

## Network Layout

```
Laptop ──Tailscale──> GCP Server ──> Internet
         (dashboard)   (exit node)

Phone ──Tailscale──> GCP Server ──> Internet
        (app)         (exit node)
```

## Access Points

| Service | URL | Access |
|---------|-----|--------|
| Dashboard | `http://127.0.0.1:7979` | Localhost only |
| SSH | `ssh admin@<server-ip>` | Restricted to `49.37.112.107/32` |
| WireGuard | `<server-ip>:51820/UDP` | Public (for direct connections) |

## Firewall Rules (Servers)

| Rule | Port | Source | Target |
|------|------|--------|--------|
| SSH | 22/tcp | `49.37.112.107/32` | `wireguard` tag |
| WireGuard | 51820/UDP | `0.0.0.0/0` | `wireguard` tag |

No dashboard port exposed — it runs locally.

## Costs

- 4x e2-micro instances (us-east1 + us-west1 = free tier eligible)
- Asia + Europe regions incur charges (~$5-10/month total)
- No Cloud Functions needed

## Benefits

1. **One-tap switching** — click server, done
2. **No QR codes** — Tailscale handles everything
3. **Secure** — dashboard not exposed to internet
4. **Fastest server** — fping-based latency testing
5. **Clean UI** — light/dark theme, minimal design
6. **Low latency** — Tailscale mesh is faster than WireGuard hop
7. **Portable** — dashboard runs on any device with Tailscale

## Limitations

1. **Phone still needs manual Tailscale switching** — can't control phone from dashboard
2. **Dashboard only on laptop** — not accessible from phone browser
3. **Requires Tailscale installed** on the machine running dashboard
4. **fping dependency** — for latency testing (optional)

## Migration Steps

1. Deploy `files/server.py` to laptop
2. Install `files/vpn-dash` to `~/.local/bin/`
3. Set up `files/vpn-dash.service` as systemd user service
4. Remove server-side dashboard (port 8080)
5. Keep servers as Tailscale exit nodes
6. Phone uses Tailscale app for switching
