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
