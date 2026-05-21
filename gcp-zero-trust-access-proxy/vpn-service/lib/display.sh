#!/usr/bin/env bash
# display.sh — status, regions table, help output

# Latency → colored display
latency_colored() {
  local lat="$1"
  if [[ "$lat" == "timeout" ]] || [[ "$lat" == "N/A" ]]; then
    echo -e "${RED}${lat}${RST}"
  else
    local ms
    ms=$(echo "$lat" | tr -d 'ms')
    if (( ms < 50 )); then
      echo -e "${GRN}${lat}${RST}"
    elif (( ms < 150 )); then
      echo -e "${YLW}${lat}${RST}"
    else
      echo -e "${RED}${lat}${RST}"
    fi
  fi
}

# ── Status ────────────────────────────────────────────────────────────────────

cmd_status() {
  echo ""
  echo -e "  ${BLD}VPN Service${RST}  ${DIM}$(date '+%a %b %d %H:%M:%S')${RST}"
  echo ""

  # Tailscale connection state
  local ts_info
  ts_info=$(ts_status_summary)
  local ts_state ts_host ts_pubip
  IFS='|' read -r ts_state ts_host ts_pubip <<< "$ts_info"

  if [[ "$ts_state" == "connected" ]]; then
    echo -e "  ${GRN}●${RST} ${BLD}Connected${RST}"
    echo -e "    Exit node : ${CYN}${ts_host}${RST}"
    echo -e "    Public IP : ${GRN}${ts_pubip}${RST}"
    echo -e "    Dashboard : ${CYN}http://$(tailscale ip -4 2>/dev/null || echo '?'):8080${RST}"
    echo ""
    echo -e "  ${BLD}Share this with others:${RST}"
    echo -e "    ${CYN}http://$(tailscale ip -4 2>/dev/null || echo '?'):8080${RST}"
    echo -e "    ${DIM}They'll see a setup wizard to join via Tailscale${RST}"
  else
    echo -e "  ${DIM}○${RST} ${DIM}Disconnected${RST}"
  fi

  # GCP server state
  local active_region active_ip up_since
  active_region=$(state_get "region")
  active_ip=$(state_get "ip")
  up_since=$(state_get "up_since")

  if [[ -n "$active_region" ]]; then
    local flag elapsed_str=""
    flag=$(region_flag "$active_region")
    [[ -n "$up_since" ]] && elapsed_str=" (up $(elapsed_since "$up_since"))"
    echo ""
    echo -e "  ${BLD}GCP Server${RST}"
    echo -e "    Region    : ${flag} ${active_region}${elapsed_str}"
    [[ -n "$active_ip" ]] && echo -e "    Public IP : ${active_ip}"
  else
    echo ""
    echo -e "  ${DIM}No server running. Run 'vpn up' to start one.${RST}"
  fi

  # Auto-teardown timer
  if [[ -f "$VPN_TIMER_FILE" ]]; then
    local sched_ts
    sched_ts=$(cat "$VPN_TIMER_FILE")
    local now
    now=$(date +%s)
    if (( sched_ts > now )); then
      local mins=$(( (sched_ts - now) / 60 ))
      echo ""
      echo -e "  ${YLW}⏱${RST}  Auto-teardown in ${mins} minutes"
      echo -e "     Run '${DIM}vpn cancel-down${RST}' to cancel"
    fi
  fi

  echo ""
}

# ── Regions ───────────────────────────────────────────────────────────────────

cmd_regions() {
  echo ""
  echo -e "  ${BLD}Available Regions${RST}  ${DIM}(probing latency…)${RST}"
  echo ""

  local active_region
  active_region=$(state_get "region")

  printf "  %-4s %-24s %-10s %s\n" "" "Region" "Latency" "IP"
  echo -e "  ${DIM}$(printf '%.0s─' {1..55})${RST}"

  local i=1
  while IFS=' ' read -r region latency ip; do
    [[ -z "$region" ]] && continue
    local flag active_marker=""
    flag=$(region_flag "$region")
    [[ "$region" == "$active_region" ]] && active_marker=" ${GRN}← active${RST}"

    local lat_colored
    lat_colored=$(latency_colored "$latency")

    printf "  %-2s  ${flag} %-20s " "$i" "$region"
    echo -e "${lat_colored}  ${ip:-?}${active_marker}"
    (( i++ ))
  done < <(probe_all_latencies)

  echo ""
  echo -e "  ${DIM}Usage: vpn up <region>   e.g.  vpn up asia-south1${RST}"
  echo ""
}

# ── Help ──────────────────────────────────────────────────────────────────────

cmd_help() {
  cat <<EOF

  ${BLD}vpn${RST} — on-demand GCP VPN service

  ${BLD}COMMANDS${RST}
    ${CYN}vpn up [region]${RST}         Provision server + connect via Tailscale
    ${CYN}vpn down${RST}                Disconnect + destroy server (zero cost)
    ${CYN}vpn switch [region]${RST}     Switch region (down + up)
    ${CYN}vpn status${RST}              Show connection state + dashboard URL
    ${CYN}vpn regions${RST}             List regions with live latency
    ${CYN}vpn ls${RST}                  Alias for regions
    ${CYN}vpn connect [region]${RST}    Connect to running server (no provision)
    ${CYN}vpn logs${RST}                Follow VPN service logs
    ${CYN}vpn schedule-down [min]${RST} Auto-teardown after N minutes (default 20)
    ${CYN}vpn cancel-down${RST}         Cancel pending auto-teardown

  ${BLD}DASHBOARD${RST}
    After ${CYN}vpn up${RST}, the web dashboard runs on port 8080.
    Anyone on your Tailscale network can open it:
      http://<tailscale-ip>:8080

    ${BLD}Mobile/Other devices:${RST}
    1. Install Tailscale (App Store / Play Store / tailscale.com/download)
    2. Open Tailscale → Settings → Use auth key → paste the key from config
    3. Open http://<tailscale-ip>:8080 → choose server → freeip.me

    ${BLD}Desktop:${RST}
    1. Install Tailscale (tailscale.com/download)
    2. Authenticate with your auth key
    3. Open dashboard → pick server → verify at freeip.me

  ${BLD}EXAMPLES${RST}
    vpn up                  # Fastest region
    vpn up europe-west1     # Specific region
    vpn up asia-south1      # Mumbai
    vpn schedule-down 60    # Tear down in 1 hour
    vpn switch us-east1     # Move to US East

  ${BLD}COST${RST}
    Server running (e2-micro preemptible) : ~\$0.003/hr
    Server down                           : \$0.00
    2-hour session                        : ~\$0.006

  ${BLD}CONFIG${RST}  ${DIM}~/.config/vpn-service/config.sh${RST}
    VPN_TERRAFORM_DIR   Path to Terraform directory
    VPN_PROJECT         GCP project ID
    VPN_TS_AUTHKEY      Tailscale reusable auth key
    VPN_DEFAULT_REGION  Preferred region (empty = fastest)

EOF
}

# ── Logs ──────────────────────────────────────────────────────────────────────

cmd_logs() {
  echo -e "${DIM}Tailing ${VPN_LOG_FILE}…  (Ctrl-C to stop)${RST}"
  tail -f "$VPN_LOG_FILE"
}
