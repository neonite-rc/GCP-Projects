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
