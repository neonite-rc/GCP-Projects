#!/bin/bash
# wg-keepalive.sh — server-side keepalive for stateful middleboxes.
# Pings every configured client tunnel IP every 15s so NAT mappings on home
# routers / carrier CGNAT don't expire between client handshakes. WireGuard is
# silent by design; the client PersistentKeepalive covers the client side, this
# covers the server side.
set -euo pipefail

WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"

while true; do
  peers=$(grep -oP 'AllowedIPs\s*=\s*\K[\d.]+' "$WG_CONF" || true)
  for ip in $peers; do
    ping -c1 -W1 -q "$ip" >/dev/null 2>&1 || true
  done
  sleep 15
done
