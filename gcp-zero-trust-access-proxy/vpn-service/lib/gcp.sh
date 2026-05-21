#!/usr/bin/env bash
# gcp.sh — GCP + Terraform lifecycle management

# ── Region map ────────────────────────────────────────────────────────────────
# All supported regions with their zones, subnet CIDRs, and WireGuard CIDRs.
# This is the single source of truth for available regions.

declare -A REGION_ZONES=(
  ["us-east1"]="us-east1-b"
  ["us-west1"]="us-west1-a"
  ["asia-south1"]="asia-south1-a"
  ["asia-east1"]="asia-east1-a"
  ["asia-southeast1"]="asia-southeast1-a"
  ["europe-west1"]="europe-west1-b"
  ["europe-west4"]="europe-west4-a"
  ["europe-west2"]="europe-west2-a"
  ["asia-northeast1"]="asia-northeast1-a"
  ["southamerica-east1"]="southamerica-east1-a"
)

# Region → flag emoji
region_flag() {
  case "$1" in
    us-*) echo "🇺🇸" ;;
    europe-west1|europe-west4) echo "🇧🇪" ;;
    europe-west2) echo "🇬🇧" ;;
    asia-south1) echo "🇮🇳" ;;
    asia-east1) echo "🇹🇼" ;;
    asia-southeast1) echo "🇸🇬" ;;
    asia-northeast1) echo "🇯🇵" ;;
    southamerica-east1) echo "🇧🇷" ;;
    *) echo "🌐" ;;
  esac
}

# All region names
get_regions() {
  echo "${!REGION_ZONES[@]}" | tr ' ' '\n' | sort
}

# Validate a region name
validate_region() {
  local region="$1"
  [[ -n "${REGION_ZONES[$region]+_}" ]]
}

# Get zone for a region
region_zone() {
  echo "${REGION_ZONES[$1]:-${1}-a}"
}

# ── Latency probing ──────────────────────────────────────────────────────────

# Probe latency to a single IP using fping (fast, accurate)
probe_latency() {
  local ip="$1"
  [[ -z "$ip" ]] && { echo "N/A"; return; }
  local result
  result=$(fping -C 1 -q --timeout=2000 "$ip" 2>&1 | awk -F: '{print $2}' | tr -d ' ')
  if [[ "$result" == "-" ]] || [[ -z "$result" ]]; then
    echo "timeout"
  else
    printf "%.0fms" "$result"
  fi
}

# Probe all regions concurrently, output "region latency ip" sorted by latency
probe_all_latencies() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  # Get all known server IPs from Terraform or env
  local endpoints_file="$tmpdir/endpoints"
  get_endpoints > "$endpoints_file" 2>/dev/null || true

  while IFS='=' read -r region ip; do
    [[ -z "$ip" ]] && continue
    (
      latency=$(probe_latency "$ip")
      echo "$region $latency $ip" > "$tmpdir/$region"
    ) &
  done < "$endpoints_file"
  wait

  # Sort: numeric latencies first, then "timeout", then "N/A"
  cat "$tmpdir"/* 2>/dev/null | sort -k2 -V 2>/dev/null || true
}

# ── Endpoint discovery ───────────────────────────────────────────────────────

get_endpoints() {
  # 1. From env var
  if [[ -n "${VPN_ENDPOINTS:-}" ]]; then
    tr ',' '\n' <<< "$VPN_ENDPOINTS"
    return
  fi

  # 2. From Terraform output
  if [[ -d "$VPN_TERRAFORM_DIR" ]]; then
    local tf_out
    if tf_out=$(cd "$VPN_TERRAFORM_DIR" && terraform output -json all_regions 2>/dev/null); then
      echo "$tf_out" | jq -r 'to_entries[] | "\(.key)=\(.value.public_ip // .value)"' 2>/dev/null
      return
    fi
  fi

  # 3. Empty — no servers known
  warn "No endpoints found. Run 'vpn up' to provision a server."
}

# ── Terraform lifecycle ──────────────────────────────────────────────────────

tf() {
  cd "$VPN_TERRAFORM_DIR" && terraform "$@"
}

# Bring up a server in a region
terraform_up() {
  local region="$1"
  local zone
  zone=$(region_zone "$region")

  step "Provisioning server in ${region} (${zone})…"

  if [[ ! -d "$VPN_TERRAFORM_DIR" ]]; then
    err "Terraform directory not found: $VPN_TERRAFORM_DIR"
    echo "  Set VPN_TERRAFORM_DIR in $VPN_CONFIG_FILE"
    exit 1
  fi

  local start_ts
  start_ts=$(date +%s)

  # Build terraform apply args
  local tf_args=(
    apply -auto-approve
    -var "active_region=${region}"
    -var "enable_server=true"
  )
  [[ -n "$VPN_PROJECT" ]] && tf_args+=(-var "project=${VPN_PROJECT}")
  [[ -n "$VPN_MACHINE_TYPE" ]] && tf_args+=(-var "machine_type=${VPN_MACHINE_TYPE}")
  [[ -n "$VPN_TS_AUTHKEY" ]] && tf_args+=(-var "ts_authkey=${VPN_TS_AUTHKEY}")

  if tf "${tf_args[@]}" 2>&1 | tee -a "$VPN_LOG_FILE"; then
    local elapsed
    elapsed=$(elapsed_since "$start_ts")
    ok "Server provisioned in ${elapsed}"

    # Pull IP from terraform output
    local ip
    ip=$(tf output -raw server_ip 2>/dev/null || echo "")
    echo "$ip"
  else
    err "Terraform apply failed for region: ${region}"
    exit 1
  fi
}

# Tear down the active server
terraform_down() {
  local region="$1"

  step "Destroying server in ${region}…"

  local start_ts
  start_ts=$(date +%s)

  local tf_args=(
    apply -auto-approve
    -var "active_region=${region}"
    -var "enable_server=false"
  )
  [[ -n "$VPN_PROJECT" ]] && tf_args+=(-var "project=${VPN_PROJECT}")

  if tf "${tf_args[@]}" 2>&1 | tee -a "$VPN_LOG_FILE"; then
    local elapsed
    elapsed=$(elapsed_since "$start_ts")
    ok "Server destroyed in ${elapsed}"
  else
    warn "apply failed, trying terraform destroy…"
    tf destroy -auto-approve \
      -var "active_region=${region}" \
      -var "enable_server=true" \
      2>&1 | tee -a "$VPN_LOG_FILE" || true
  fi
}

# ── Region selection ─────────────────────────────────────────────────────────

pick_fastest_region() {
  info "Probing latencies to find fastest region…"
  local fastest
  fastest=$(probe_all_latencies | grep -v "timeout\|N/A" | head -1 | awk '{print $1}')
  echo "$fastest"
}

pick_random_region() {
  get_regions | shuf -n 1
}
