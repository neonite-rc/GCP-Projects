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
