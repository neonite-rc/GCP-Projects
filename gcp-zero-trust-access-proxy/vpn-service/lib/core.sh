#!/usr/bin/env bash
# core.sh — shared state, logging, config, locking
#
# Every state mutation goes through state_set/state_get/state_clear.
# State is a flat JSON file at ~/.local/state/vpn-service/state.json.

# ── Directories ──────────────────────────────────────────────────────────────
VPN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vpn-service"
VPN_LOG_FILE="$VPN_STATE_DIR/vpn.log"
VPN_STATE_FILE="$VPN_STATE_DIR/state.json"
VPN_LOCK_FILE="$VPN_STATE_DIR/vpn.lock"
VPN_TIMER_FILE="$VPN_STATE_DIR/auto-down.timer"
VPN_TIMER_PID_FILE="$VPN_STATE_DIR/auto-down.pid"

# ── Config ───────────────────────────────────────────────────────────────────
VPN_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/vpn-service/config.sh"

# Defaults (override in config.sh)
VPN_TERRAFORM_DIR="${VPN_TERRAFORM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)}"
VPN_PROJECT="${VPN_PROJECT:-}"
VPN_TAILNET="${VPN_TAILNET:-}"
VPN_TS_TAG="${VPN_TS_TAG:-tag:vpn}"
VPN_CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-120}"
VPN_DEFAULT_REGION="${VPN_DEFAULT_REGION:-}"
VPN_MACHINE_TYPE="${VPN_MACHINE_TYPE:-e2-micro}"
VPN_TS_AUTHKEY="${VPN_TS_AUTHKEY:-}"

[[ -f "$VPN_CONFIG_FILE" ]] && source "$VPN_CONFIG_FILE"

mkdir -p "$VPN_STATE_DIR"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'
  BLU='\033[0;34m'; MAG='\033[0;35m'; CYN='\033[0;36m'
  DIM='\033[2m';    BLD='\033[1m';    RST='\033[0m'
else
  RED=''; GRN=''; YLW=''; BLU=''; MAG=''; CYN=''
  DIM=''; BLD=''; RST=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$VPN_LOG_FILE"; }
info() { echo -e "${BLU}→${RST} $*"; _log "INFO  $*"; }
ok()   { echo -e "${GRN}✓${RST} $*"; _log "OK    $*"; }
warn() { echo -e "${YLW}⚠${RST}  $*"; _log "WARN  $*"; }
err()  { echo -e "${RED}✗${RST} $*" >&2; _log "ERROR $*"; }
step() { echo -e "\n${BLD}${CYN}── $* ──${RST}"; _log "STEP  $*"; }

# ── Locking ───────────────────────────────────────────────────────────────────
acquire_lock() {
  if [[ -f "$VPN_LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$VPN_LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      err "Another vpn operation is running (PID $pid)."
      exit 1
    fi
    warn "Stale lock found, removing."
    rm -f "$VPN_LOCK_FILE"
  fi
  echo $$ > "$VPN_LOCK_FILE"
  trap 'rm -f "$VPN_LOCK_FILE"' EXIT INT TERM
}

# ── State ─────────────────────────────────────────────────────────────────────
state_set() {
  local key="$1" val="$2"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$VPN_STATE_FILE" ]]; then
    jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$VPN_STATE_FILE" > "$tmp"
  else
    jq -n --arg k "$key" --arg v "$val" '{($k): $v}' > "$tmp"
  fi
  mv "$tmp" "$VPN_STATE_FILE"
}

state_get() {
  local key="$1"
  if [[ -f "$VPN_STATE_FILE" ]]; then
    jq -r --arg k "$key" '.[$k] // empty' "$VPN_STATE_FILE"
  fi
}

state_clear() {
  echo '{}' > "$VPN_STATE_FILE"
}

# ── Dependency check ──────────────────────────────────────────────────────────
require_deps() {
  local missing=()
  for dep in gcloud terraform jq tailscale fping; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing dependencies: ${missing[*]}"
    echo "  Install: brew install jq fping tailscale"
    echo "  gcloud: https://cloud.google.com/sdk/docs/install"
    echo "  terraform: https://developer.hashicorp.com/terraform/install"
    exit 1
  fi
}

# ── Elapsed time ──────────────────────────────────────────────────────────────
elapsed_since() {
  local ts="$1"
  local now
  now=$(date +%s)
  local diff=$(( now - ts ))
  if (( diff < 60 )); then
    echo "${diff}s"
  elif (( diff < 3600 )); then
    echo "$(( diff / 60 ))m $(( diff % 60 ))s"
  else
    echo "$(( diff / 3600 ))h $(( (diff % 3600) / 60 ))m"
  fi
}
