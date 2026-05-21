#!/usr/bin/env bash
# tailscale.sh — Tailscale exit node management

# ── Exit node discovery ──────────────────────────────────────────────────────

# List all exit nodes: "hostname tailscale_ip" lines
ts_exit_nodes() {
  tailscale status --json 2>/dev/null \
    | jq -r '
        .Peer[]
        | select(.ExitNodeOption == true)
        | "\(.HostName) \(.TailscaleIPs[0])"
      ' 2>/dev/null || true
}

# Find Tailscale hostname for a GCP region
# Matches region name against Tailscale hostnames (e.g. "vpn-asia-south1")
ts_node_for_region() {
  local region="$1"
  ts_exit_nodes | grep -i "$region" | head -1 | awk '{print $1}'
}

# Current exit node hostname (empty if not connected)
ts_current_exit_hostname() {
  tailscale status --json 2>/dev/null \
    | jq -r '
        .Peer[]
        | select(.Active == true and .ExitNode == true)
        | .HostName
      ' 2>/dev/null || true
}

# Current exit node IP (empty if not connected)
ts_current_exit_ip() {
  tailscale status --json 2>/dev/null \
    | jq -r '.ExitNodeStatus.TailscaleIPs[0] // empty' 2>/dev/null || true
}

# ── Wait for node ────────────────────────────────────────────────────────────

# Wait for a Tailscale exit node to appear after provisioning
# Returns the hostname on success, exits on timeout
ts_wait_for_node() {
  local region="$1"
  local timeout="${2:-$VPN_CONNECT_TIMEOUT}"
  local interval=5
  local elapsed=0

  info "Waiting for Tailscale node in ${region} to come online…"
  echo -n "  "

  while (( elapsed < timeout )); do
    local node
    node=$(ts_node_for_region "$region")
    if [[ -n "$node" ]]; then
      echo ""
      ok "Node online: ${node}"
      echo "$node"
      return 0
    fi
    echo -n "."
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done

  echo ""
  err "Timeout: node for ${region} did not appear within ${timeout}s"
  echo "  Server may still be booting. Try 'vpn connect' in a minute."
  return 1
}

# ── Connect / disconnect ─────────────────────────────────────────────────────

ts_connect_exit_node() {
  local hostname="$1"

  # Disconnect current exit node first
  local current
  current=$(ts_current_exit_hostname)
  if [[ -n "$current" ]]; then
    if [[ "$current" == "$hostname" ]]; then
      ok "Already connected to: ${hostname}"
      return 0
    fi
    info "Disconnecting from: ${current}"
    tailscale set --exit-node="" 2>/dev/null || true
    sleep 1
  fi

  info "Connecting to exit node: ${hostname}"
  if tailscale set --exit-node="$hostname" --exit-node-allow-lan-access=true; then
    ok "VPN active via Tailscale → ${hostname}"

    # Verify connectivity
    sleep 2
    local pub_ip
    pub_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    info "Public IP: ${pub_ip}"
    return 0
  else
    err "Failed to set exit node: ${hostname}"
    return 1
  fi
}

ts_disconnect() {
  local current
  current=$(ts_current_exit_hostname)
  if [[ -z "$current" ]]; then
    warn "No active exit node to disconnect."
    return 0
  fi

  info "Disconnecting exit node: ${current}"
  tailscale set --exit-node="" 2>/dev/null
  ok "Disconnected from Tailscale exit node."
}

# ── Status ────────────────────────────────────────────────────────────────────

# Returns "state|hostname|public_ip"
ts_status_summary() {
  local current_host
  current_host=$(ts_current_exit_hostname)

  if [[ -n "$current_host" ]]; then
    local pub_ip
    pub_ip=$(curl -sf --max-time 4 https://api.ipify.org 2>/dev/null || echo "unknown")
    echo "connected|${current_host}|${pub_ip}"
  else
    echo "disconnected||"
  fi
}
