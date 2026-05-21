#!/usr/bin/env bash
# commands.sh — cmd_up / cmd_down / cmd_switch / cmd_connect / schedule

# ── vpn up ────────────────────────────────────────────────────────────────────

cmd_up() {
  require_deps
  acquire_lock

  local region="${1:-}"

  # Check if already up
  local current_region
  current_region=$(state_get "region")
  if [[ -n "$current_region" ]]; then
    warn "Server already running in: ${current_region}"
    echo "  Use 'vpn switch ${region:-<region>}' to change, or 'vpn down' first."
    exit 0
  fi

  # Resolve region
  if [[ -z "$region" ]]; then
    if [[ -n "${VPN_DEFAULT_REGION:-}" ]]; then
      region="$VPN_DEFAULT_REGION"
      info "Using default region: ${region}"
    else
      info "No region specified — picking fastest…"
      region=$(pick_fastest_region)
      if [[ -z "$region" ]]; then
        warn "Latency probe failed, picking random."
        region=$(pick_random_region)
      fi
    fi
  fi

  # Validate
  if ! validate_region "$region"; then
    err "Unknown region: ${region}"
    echo "  Run 'vpn regions' to see available regions."
    exit 1
  fi

  local flag
  flag=$(region_flag "$region")
  step "${flag} Starting VPN in ${region}…"

  # Provision
  local ip
  ip=$(terraform_up "$region")

  # Save state
  state_set "region" "$region"
  state_set "ip" "$ip"
  state_set "up_since" "$(date +%s)"
  state_set "status" "provisioned"

  # Wait for Tailscale exit node
  local ts_hostname
  if ts_hostname=$(ts_wait_for_node "$region" "$VPN_CONNECT_TIMEOUT"); then
    ts_connect_exit_node "$ts_hostname"
    state_set "ts_hostname" "$ts_hostname"
    state_set "status" "connected"
  else
    warn "Server is up but Tailscale node not yet visible."
    echo "  Run 'vpn connect' once the server finishes booting."
  fi

  echo ""
  cmd_status
}

# ── vpn down ──────────────────────────────────────────────────────────────────

cmd_down() {
  require_deps
  acquire_lock

  local region
  region=$(state_get "region")

  if [[ -z "$region" ]]; then
    warn "No active VPN server found."
    exit 0
  fi

  step "Tearing down VPN…"

  # 1. Disconnect Tailscale
  ts_disconnect

  # 2. Cancel auto-teardown
  rm -f "$VPN_TIMER_FILE"
  if [[ -f "$VPN_TIMER_PID_FILE" ]]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$VPN_TIMER_PID_FILE"
    rm -f "$VPN_TIMER_PID_FILE"
  fi

  # 3. Terraform destroy
  terraform_down "$region"

  # 4. Clear state
  state_clear
  ok "VPN torn down. No GCP resources running."
}

# ── vpn switch ────────────────────────────────────────────────────────────────

cmd_switch() {
  local new_region="${1:-}"

  local current_region
  current_region=$(state_get "region")

  if [[ -n "$current_region" ]] && [[ "$current_region" == "$new_region" ]]; then
    warn "Already in region: ${current_region}"
    exit 0
  fi

  step "Switching: ${current_region:-none} → ${new_region:-auto}"

  # Down first
  if [[ -n "$current_region" ]]; then
    info "Bringing down ${current_region}…"
    # Inline teardown (avoid recursive lock)
    ts_disconnect
    rm -f "$VPN_TIMER_FILE"
    terraform_down "$current_region"
    state_clear
  fi

  # Up in new region
  cmd_up "$new_region"
}

# ── vpn connect ───────────────────────────────────────────────────────────────

cmd_connect() {
  require_deps

  local region="${1:-$(state_get 'region')}"

  if [[ -z "$region" ]]; then
    err "No region specified and no active server in state."
    echo "  Usage: vpn connect <region>"
    exit 1
  fi

  info "Looking for Tailscale exit node: ${region}"
  local ts_hostname
  ts_hostname=$(ts_node_for_region "$region")

  if [[ -z "$ts_hostname" ]]; then
    warn "No Tailscale exit node found for: ${region}"
    echo ""
    echo "  Known exit nodes:"
    ts_exit_nodes | while read -r h ip; do
      echo "    ${h}  (${ip})"
    done
    echo ""
    echo "  Is the server running? Try: vpn up ${region}"
    exit 1
  fi

  ts_connect_exit_node "$ts_hostname"
  state_set "ts_hostname" "$ts_hostname"
  state_set "status" "connected"

  echo ""
  cmd_status
}

# ── vpn schedule-down ─────────────────────────────────────────────────────────

cmd_schedule_down() {
  local minutes="${1:-20}"

  if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
    err "Invalid duration: ${minutes}. Must be a positive integer (minutes)."
    exit 1
  fi

  local teardown_ts
  teardown_ts=$(( $(date +%s) + minutes * 60 ))
  echo "$teardown_ts" > "$VPN_TIMER_FILE"

  # Background teardown process
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/vpn"

  nohup bash -c "
    sleep $(( minutes * 60 ))
    rm -f '$VPN_TIMER_FILE'
    '$self' down
    notify-send 'VPN' 'Auto-teardown complete.' 2>/dev/null || true
  " >> "$VPN_LOG_FILE" 2>&1 &

  local pid=$!
  echo "$pid" > "$VPN_TIMER_PID_FILE"

  ok "Auto-teardown scheduled in ${minutes} minutes"
  echo -e "  ${DIM}At: $(date -d "@$teardown_ts" '+%H:%M:%S') today${RST}"
  echo -e "  Run '${DIM}vpn cancel-down${RST}' to cancel"
}

# ── vpn cancel-down ───────────────────────────────────────────────────────────

cmd_cancel_down() {
  if [[ ! -f "$VPN_TIMER_FILE" ]]; then
    warn "No auto-teardown is scheduled."
    exit 0
  fi

  rm -f "$VPN_TIMER_FILE"
  if [[ -f "$VPN_TIMER_PID_FILE" ]]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$VPN_TIMER_PID_FILE"
    rm -f "$VPN_TIMER_PID_FILE"
  fi

  ok "Auto-teardown cancelled."
}
