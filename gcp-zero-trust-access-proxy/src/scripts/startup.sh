#!/bin/bash
# GENERATED — do not edit by hand. Edit src/scripts/startup.sh.tmpl and the
# canonical sources (src/scripts/{lib,*.sh} and src/scripts/fragments/), then
# run src/scripts/build-startup.sh. CI checks startup.sh is up to date.
# Startup script: installs and configures WireGuard + security hardening.
# Runs via GCE metadata_startup_script.
#   - DuckDNS: always updates on boot (handles ephemeral IP changes)
#   - WireGuard + hardening + tooling: first boot only (marker file)
set -euo pipefail

MARKER=/var/lib/wireguard-setup-done

# --- Read metadata ---
WG_PORT=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/wg-port") || WG_PORT=51820
WG_CIDR=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/wg-cidr") || WG_CIDR=10.200.200.0/24

WG_NET="${WG_CIDR%/*}"
WG_PREFIX="${WG_CIDR#*/}"
WG_SERVER_IP="${WG_NET%.*}.1/${WG_PREFIX}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools ufw fail2ban unattended-upgrades qrencode

# ===== ALWAYS-ON: DuckDNS dynamic DNS =====
# Runs on every boot so the hostname always points to the current ephemeral IP.
DUCKDNS_DOMAIN=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/duckdns-domain") || DUCKDNS_DOMAIN=""
DUCKDNS_TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/duckdns-token") || DUCKDNS_TOKEN=""

if [ -n "$DUCKDNS_DOMAIN" ] && [ -n "$DUCKDNS_TOKEN" ]; then
  cat > /etc/duckdns.env <<ENVEOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
ENVEOF
  chmod 600 /etc/duckdns.env

  cat > /usr/local/sbin/duckns-update.sh <<'DUCKEOF'
#!/bin/bash
# DuckDNS dynamic DNS updater.
# Queries the VM's public IP and reports it to DuckDNS.
# Runs via systemd timer every 5 minutes.
# Usage: DUCKDNS_TOKEN=<token> DUCKDNS_DOMAIN=<domain> /usr/local/sbin/duckns-update.sh
set -euo pipefail

: "${DUCKDNS_TOKEN:?Set DUCKDNS_TOKEN in /etc/duckdns.env}"
: "${DUCKDNS_DOMAIN:?Set DUCKDNS_DOMAIN in /etc/duckdns.env}"

CURRENT_IP=$(curl -sf https://api.ipify.org || curl -sf https://ifconfig.me || \
  { echo "Failed to detect public IP"; exit 1; })

RESPONSE=$(curl -sf "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${CURRENT_IP}&verbose=true" || \
  { echo "Failed to contact DuckDNS API"; exit 1; })

logger -t duckns-update "IP=${CURRENT_IP} response=${RESPONSE}"
echo "$(date '+%Y-%m-%d %H:%M:%S %Z')  IP=${CURRENT_IP}  response=${RESPONSE}" >> /var/log/duckns-update.log
DUCKEOF
  chmod 700 /usr/local/sbin/duckns-update.sh

  cat > /etc/systemd/system/duckns-update.service <<'DUCKSVCEOF'
[Unit]
Description=DuckDNS dynamic DNS updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/duckdns.env
ExecStart=/usr/local/sbin/duckns-update.sh
DUCKSVCEOF

  cat > /etc/systemd/system/duckns-update.timer <<'DUCKTIMEOF'
[Unit]
Description=Update DuckDNS every 1 minute

[Timer]
OnBootSec=30sec
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
DUCKTIMEOF

  cat > /etc/logrotate.d/duckns-update <<'DUCKLOGRATEEOF'
/var/log/duckns-update.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0644 root root
}
DUCKLOGRATEEOF

  systemctl daemon-reload
  systemctl enable --now duckns-update.timer
  /usr/local/sbin/duckns-update.sh || true
  echo "DuckDNS configured: ${DUCKDNS_DOMAIN}.duckdns.org"
else
  echo "DuckDNS not configured (no domain/token in metadata)"
fi

# ===== FIRST-BOOT ONLY: WireGuard + hardening =====
if [ -f "$MARKER" ]; then
  echo "WireGuard already configured (marker exists). DuckDNS updated on boot."
  exit 0
fi

# --- WireGuard server keys ---
umask 077
mkdir -p /etc/wireguard/clients
if [ ! -f /etc/wireguard/server_private.key ]; then
  wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
fi
SERVER_PRIV=$(cat /etc/wireguard/server_private.key)

# --- Detect primary NIC for NAT ---
NIC=$(ip -o -4 route show to default | awk '{print $5}')

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${NIC} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${NIC} -j MASQUERADE
EOF

# --- IP forwarding ---
cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward = 1
EOF
sysctl --system

systemctl enable --now wg-quick@wg0

# --- Client tooling + peer store (single source of the peer schema) ---
  cat > /usr/local/sbin/wg-peer-store.sh <<'LIBEOF'
#!/bin/bash
# wg-peer-store.sh — the single owner of the WireGuard peer schema.
#
# Every read and mutation of the WireGuard server config (and the per-client
# configs) goes through this module, so the "# client: <name>" convention, the
# tunnel IP allocation, and the name<->public-key mapping live in exactly one
# place. Sourced by add-client.sh, remove-client.sh, and wg-activity-log.sh.
#
# Overrides (for fixture tests):
#   WG_CONF         path to wg0.conf             (default /etc/wireguard/wg0.conf)
#   WG_SERVER_KEY   server public key file       (default /etc/wireguard/server_public.key)
#   WG_CLIENT_DIR   per-client config directory  (default /etc/wireguard/clients)

WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_SERVER_KEY="${WG_SERVER_KEY:-/etc/wireguard/server_public.key}"
WG_CLIENT_DIR="${WG_CLIENT_DIR:-/etc/wireguard/clients}"

declare -A PEER_NAMES=()

peer_sanitize() {
  tr -c 'A-Za-z0-9_-' '_' <<<"$1"
}

peer_validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]
}

peer_exists() {
  [ -f "$WG_CLIENT_DIR/$1.conf" ]
}

peer_client_path() {
  printf '%s/%s.conf\n' "$WG_CLIENT_DIR" "$1"
}

peer_server_public_key() {
  cat "$WG_SERVER_KEY"
}

peer_listen_port() {
  grep -oP '^ListenPort\s*=\s*\K\d+' "$WG_CONF"
}

peer_server_address() {
  grep -oP '^Address\s*=\s*\K[\d.]+' "$WG_CONF"
}

peer_subnet_prefix() {
  peer_server_address | cut -d. -f1-3
}

peer_next_ip() {
  local prefix used next
  prefix=$(peer_subnet_prefix)
  used=$(grep -oP 'AllowedIPs\s*=\s*\K[\d.]+' "$WG_CONF" | cut -d. -f4 | sort -n || true)
  next=2
  for i in $used; do
    [ "$i" -eq "$next" ] && next=$((next + 1))
  done
  printf '%s.%s\n' "$prefix" "$next"
}

peer_endpoint() {
  local domain=""
  if [ -f /etc/duckdns.env ]; then
    domain=$(grep '^DUCKDNS_DOMAIN=' /etc/duckdns.env | cut -d= -f2)
  fi
  if [ -n "$domain" ]; then
    printf '%s.duckdns.org\n' "$domain"
  else
    curl -sf -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip"
  fi
}

# Parse wg0.conf into PEER_NAMES (public key -> client name). Tolerates the
# "# client: <name>" convention and a bare "# <name>" comment before a peer.
peer_load_names() {
  local pubkey name
  while read -r pubkey name; do
    [ -n "${pubkey:-}" ] && PEER_NAMES[$pubkey]="$name"
  done < <(awk '
    /^# client: / { name=substr($0, index($0, ":")+2); gsub(/^ +| +$/, "", name) }
    /^# [^ ]+$/ { name=substr($0, 3) }
    /^PublicKey = / { print $3, name }
  ' "$WG_CONF")
}

peer_add() { # name client_priv client_pub psk tunnel_ip endpoint
  local name=$1 cpriv=$2 cpub=$3 psk=$4 ip=$5 endpoint=$6
  local server_pub port

  umask 077
  cat >> "$WG_CONF" <<EOF

# client: ${name}
[Peer]
PublicKey = ${cpub}
PresharedKey = ${psk}
AllowedIPs = ${ip}/32
EOF

  server_pub=$(peer_server_public_key)
  port=$(peer_listen_port)
  mkdir -p "$WG_CLIENT_DIR"
  cat > "$WG_CLIENT_DIR/$name.conf" <<EOF
[Interface]
PrivateKey = ${cpriv}
Address = ${ip}/24
DNS = 8.8.8.8

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${endpoint}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

peer_remove() { # name
  local name=$1
  sed -i "/^# client: ${name}$/,/^AllowedIPs/d" "$WG_CONF"
  sed -i '/^$/N;/^\n$/D' "$WG_CONF"
  rm -f "$WG_CLIENT_DIR/$name.conf"
}
LIBEOF
chmod 700 /usr/local/sbin/wg-peer-store.sh

  cat > /usr/local/sbin/add-client.sh <<'ADDCLIENTEOF'
#!/bin/bash
# Adds a WireGuard client (peer) on the server and prints its config + QR code.
#
# Usage:
#   sudo ./add-client.sh <name>                           # add to this server only
#   sudo ./add-client.sh --region all <name>              # add to all servers via SSH
#   sudo ./add-client.sh --region <region-key> <name>     # add to a specific region
#
# For --region all, set REGION_SSH_HOSTS env var:
#   export REGION_SSH_HOSTS="us-west1=admin@35.x,asia-south1=admin@34.x"
#
# If REGION_SSH_HOSTS is not set, the script tries to read from Terraform output:
#   terraform -chdir=/opt/gcp-vpn-server/terraform output -json all_regions
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }

REGION="local"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="$2"; shift 2
      ;;
    *)
      NAME="$1"; shift
      ;;
  esac
done

[ -n "${NAME:-}" ] || { echo "Usage: $0 [--region local|all|<region-key>] <client-name>"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wg-peer-store.sh
if [ -f /usr/local/sbin/wg-peer-store.sh ]; then
  source /usr/local/sbin/wg-peer-store.sh
else
  source "$SCRIPT_DIR/lib/wg-peer-store.sh"
fi

# --- Local add ---
add_client_local() {
  local name="$1"

  peer_validate_name "$name" || { echo "Client name must be 1-32 chars: letters, digits, - or _"; exit 1; }
  peer_exists "$name" && { echo "Client '$name' already exists"; exit 1; }

  local endpoint next_ip
  endpoint=$(peer_endpoint)
  [ -n "$endpoint" ] || { echo "Could not determine endpoint (DuckDNS or IP)"; exit 1; }

  next_ip=$(peer_next_ip)
  [ "${NEXT_IP##*.}" -le 254 ] 2>/dev/null || [ "${next_ip##*.}" -le 254 ] || { echo "Subnet full"; exit 1; }

  umask 077
  local client_priv client_pub psk
  client_priv=$(wg genkey)
  client_pub=$(echo "$client_priv" | wg pubkey)
  psk=$(wg genpsk)

  peer_add "$name" "$client_priv" "$client_pub" "$psk" "$next_ip" "$endpoint"

  wg syncconf wg0 <(wg-quick strip wg0)

  local client_file
  client_file=$(peer_client_path "$name")
  echo "Client '$name' added with IP ${next_ip} (local)"
  echo "Config: $client_file"
  echo
  cat "$client_file"
  echo
  qrencode -t ansiutf8 < "$client_file"
}

# --- Remote add via SSH ---
add_client_remote() {
  local name="$1" host="$2" region_key="$3"
  echo "Adding client '$name' to ${region_key} ($host)..."
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$host" \
    "sudo /usr/local/sbin/add-client.sh --region local '$name'" \
    && echo "  -> $region_key: done" \
    || echo "  -> $region_key: FAILED (host unreachable or add-client missing)"
}

# --- Discover remote hosts ---
get_region_hosts() {
  # 1. From env var (explicit)
  if [ -n "${REGION_SSH_HOSTS:-}" ]; then
    echo "$REGION_SSH_HOSTS"
    return
  fi

  # 2. From Terraform output (auto-discovered)
  local tf_dir="/opt/gcp-vpn-server/terraform"
  if [ -d "$tf_dir" ] && command -v terraform &>/dev/null; then
    local json
    json=$(terraform -chdir="$tf_dir" output -json all_regions 2>/dev/null || echo "")
    if [ -n "$json" ] && [ "$json" != "null" ]; then
      # Parse JSON: {"us-east1":{"ssh_command":"ssh admin@x.x.x.x",...},...}
      echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for key, val in data.items():
    cmd = val.get('ssh_command', '')
    if cmd:
        # extract user@host from 'ssh user@host'
        parts = cmd.split()
        if len(parts) >= 2:
            print(f'{key}={parts[-1]}')
" 2>/dev/null
      return
    fi
  fi

  # 3. Empty — caller must set REGION_SSH_HOSTS
  echo ""
}

# --- Execute based on --region ---

case "$REGION" in
  local)
    add_client_local "$NAME"
    ;;

  all)
    add_client_local "$NAME"

    hosts=$(get_region_hosts)
    if [ -z "$hosts" ]; then
      echo "WARNING: No remote hosts found. Set REGION_SSH_HOSTS or run from Terraform-managed VM."
      exit 0
    fi

    current_ip=$(curl -sf -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null || echo "")

    IFS=',' read -ra ENTRIES <<< "$hosts"
    for entry in "${ENTRIES[@]}"; do
      key="${entry%%=*}"
      host="${entry#*=}"
      # Skip self
      if echo "$host" | grep -q "$current_ip" 2>/dev/null; then
        continue
      fi
      add_client_remote "$NAME" "$host" "$key"
    done
    ;;

  *)
    # Specific region key — find its host
    hosts=$(get_region_hosts)
    found=""
    IFS=',' read -ra ENTRIES <<< "$hosts"
    for entry in "${ENTRIES[@]}"; do
      key="${entry%%=*}"
      if [ "$key" = "$REGION" ]; then
        found="${entry#*=}"
        break
      fi
    done

    if [ -z "$found" ]; then
      echo "ERROR: Region '$REGION' not found in REGION_SSH_HOSTS or Terraform output"
      echo "Available regions: $(echo "$hosts" | cut -d= -f1 | tr '\n' ', ')"
      exit 1
    fi

    add_client_remote "$NAME" "$found" "$REGION"
    ;;
esac
ADDCLIENTEOF
chmod 700 /usr/local/sbin/add-client.sh

  cat > /usr/local/sbin/remove-client.sh <<'REMOVECLIENTEOF'
#!/bin/bash
# Removes a WireGuard client (peer) from the server.
# Usage: sudo ./remove-client.sh <client-name>
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }
[ $# -eq 1 ] || { echo "Usage: $0 <client-name>"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wg-peer-store.sh
if [ -f /usr/local/sbin/wg-peer-store.sh ]; then
  source /usr/local/sbin/wg-peer-store.sh
else
  source "$SCRIPT_DIR/lib/wg-peer-store.sh"
fi

NAME="$1"
peer_validate_name "$NAME" || { echo "Client name must be 1-32 chars: letters, digits, - or _"; exit 1; }
peer_exists "$NAME" || { echo "Client '$NAME' not found"; exit 1; }

peer_remove "$NAME"
wg syncconf wg0 <(wg-quick strip wg0)

echo "Client '$NAME' removed and key revoked."
REMOVECLIENTEOF
chmod 700 /usr/local/sbin/remove-client.sh

  cat > /usr/local/sbin/wg-keepalive.sh <<'KEEPALIVEEOF'
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
KEEPALIVEEOF
chmod 700 /usr/local/sbin/wg-keepalive.sh

  cat > /etc/systemd/system/wg-keepalive.service <<'KEEPALIVESVCEOF'
[Unit]
Description=Keep WireGuard NAT mappings alive with peer pings
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/wg-keepalive.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
KEEPALIVESVCEOF

systemctl daemon-reload
systemctl enable --now wg-keepalive

# --- Hardening: SSH keys only ---
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh

# --- Hardening: UFW (host-level defense in depth) ---
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH (cloud firewall restricts source)'
ufw allow "${WG_PORT}/udp" comment 'WireGuard'
ufw route allow in on wg0
ufw --force enable

# --- Hardening: fail2ban ---
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
backend = systemd
maxretry = 3
bantime = 1h
findtime = 10m
EOF
systemctl enable --now fail2ban

# --- Hardening: automatic security updates ---
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- Activity logger: per-device CONNECT/DISCONNECT + traffic summary ---
  cat > /usr/local/sbin/wg-activity-log.sh <<'WGACTEOF'
#!/bin/bash
# Per-device WireGuard activity logger.
# Polls wg show dump every minute (via systemd timer), maps peers to friendly
# client names via the peer store, and logs connect/disconnect + traffic deltas
# to /var/log/wg-activity.log. ISP-style per-device activity view.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wg-peer-store.sh
if [ -f /usr/local/sbin/wg-peer-store.sh ]; then
  source /usr/local/sbin/wg-peer-store.sh
elif [ -f "$SCRIPT_DIR/lib/wg-peer-store.sh" ]; then
  source "$SCRIPT_DIR/lib/wg-peer-store.sh"
elif [ -f "$SCRIPT_DIR/../lib/wg-peer-store.sh" ]; then
  source "$SCRIPT_DIR/../lib/wg-peer-store.sh"
else
  echo "wg-peer-store.sh not found" >&2
  exit 1
fi

LOG=/var/log/wg-activity.log
STATE_DIR=/var/run/wg-activity
STALE_AFTER=180   # seconds without a handshake => considered disconnected

mkdir -p "$(dirname "$LOG")" "$STATE_DIR"

now=$(date +%s)

peer_load_names

# Normalize latest_handshake/rx/tx per peer. Dump field order:
# public_key, preshared_key, endpoint, allowed_ips, latest_handshake, rx, tx, keepalive
declare -A HS RX TX
while IFS=$'\t' read -r pub _psk _ep _ai hs rx tx _kp; do
  [ "$pub" = "interface" ] && continue
  HS[$pub]=${hs:-0}
  RX[$pub]=${rx:-0}
  TX[$pub]=${tx:-0}
done < <(wg show wg0 dump)

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG"; }

for pub in "${!HS[@]}"; do
  name="${PEER_NAMES[$pub]:-peer-${pub:0:8}}"
  sf="$STATE_DIR/$(peer_sanitize "$pub")"
  hs=${HS[$pub]}
  rx=${RX[$pub]}
  tx=${TX[$pub]}

  # previous run's state: was_active is a strict 0/1 flag
  was_active=0; prev_rx=0; prev_tx=0
  if [ -f "$sf" ]; then
    # shellcheck disable=SC1090
    source "$sf"
  fi

  is_active=0
  if [ "$hs" -ne 0 ] && [ $((now - hs)) -le "$STALE_AFTER" ]; then
    is_active=1
  fi

  if [ "$is_active" -eq 1 ] && [ "$was_active" -ne 1 ]; then
    log "CONNECT      $name    ip=${pub:0:16}..   since ${hs}E   delta_rx=$((rx-prev_rx))B delta_tx=$((tx-prev_tx))B"
  elif [ "$is_active" -eq 0 ] && [ "$was_active" -eq 1 ]; then
    log "DISCONNECT   $name    last_seen ${hs}E"
  fi

  printf 'was_active=%s prev_rx=%s prev_tx=%s\n' "$is_active" "$rx" "$tx" > "$sf"
done

# Drop state files for peers that no longer exist.
for f in "$STATE_DIR"/*; do
  [ -e "$f" ] || continue
  grep -q "$(basename "$f")" <(for p in "${!HS[@]}"; do peer_sanitize "$p"; done) || rm -f "$f"
done

# Periodic per-device traffic summary — only when at least one peer is active,
# so an idle server stays quiet.
active=0
for pub in "${!HS[@]}"; do
  hs=${HS[$pub]}
  if [ "$hs" -ne 0 ] && [ $((now - hs)) -le "$STALE_AFTER" ]; then
    active=1
  fi
done

if [ "$active" -eq 1 ]; then
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "--- traffic summary ---" >> "$LOG"
  for pub in "${!HS[@]}"; do
    name="${PEER_NAMES[$pub]:-peer-${pub:0:8}}"
    printf '  %-20s rx=%-14s tx=%-14s\n' "$name" "${RX[$pub]}" "${TX[$pub]}" >> "$LOG"
  done
fi
WGACTEOF
chmod 700 /usr/local/sbin/wg-activity-log.sh

  cat > /etc/systemd/system/wg-activity.service <<'WGACTSVCEOF'
[Unit]
Description=Per-device WireGuard activity logger
Wants=wg-quick@wg0.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-activity-log.sh
WGACTSVCEOF

  cat > /etc/systemd/system/wg-activity.timer <<'WGACTTIMEOF'
[Unit]
Description=Run WireGuard activity logger every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=30s

[Install]
WantedBy=timers.target
WGACTTIMEOF

  cat > /etc/logrotate.d/wg-activity <<'WGACTLOGRATEEOF'
/var/log/wg-activity.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}
WGACTLOGRATEEOF

systemctl daemon-reload
systemctl enable --now wg-activity.timer

# ===== Tailscale (always-on, runs on every boot) =====
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# Read Tailscale auth key from metadata (optional — if set, auto-authenticates)
TS_AUTHKEY=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ts-authkey" 2>/dev/null || echo "")

TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState',''))" 2>/dev/null || echo "")

if [ "$TS_STATE" != "Running" ]; then
  if [ -n "$TS_AUTHKEY" ]; then
    tailscale up --authkey="$TS_AUTHKEY" --advertise-exit-node --reset
  else
    # Auth URL printed to serial console for manual auth
    tailscale up --advertise-exit-node --reset 2>&1 | tee /dev/ttyS0 || true
  fi
  echo "Tailscale started"
else
  echo "Tailscale already running"
fi

touch "$MARKER"
echo "WireGuard setup complete. Public key: $(cat /etc/wireguard/server_public.key)"
