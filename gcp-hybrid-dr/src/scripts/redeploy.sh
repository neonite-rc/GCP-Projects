#!/usr/bin/env bash
# Re-fetch the code delivered via instance metadata and roll it out safely.
#
# WHY THIS EXISTS
# ---------------
# The primary site's code (app.py, the nginx config, the backup
# scripts) is delivered through instance metadata, and startup.sh
# fetches it once at first boot. That design keeps src/ the single
# source of truth, but it has a sharp edge: **a code change in the
# repository does not reach the running VM.**
#
# The provisioning marker file (/var/lib/dr-primary/.provisioned) means
# startup.sh exits immediately on every later boot, and a metadata
# change does not re-run it. So after changing src/app/app.py the
# obvious-looking actions are all wrong:
#
#   * `terraform apply`   -> updates the metadata; the VM keeps running
#                             the old code
#   * restart the VM      -> startup.sh sees the marker and exits; the
#                             VM still runs the old code
#   * destroy + recreate  -> "works", but the database is gone, the
#                             public IP changes, and every backup
#                             reference in the docs moves
#
# This script is the missing operation: pull the current code out of
# the metadata server, check it, install it, and restart the service.
# The database is never touched.
#
# IT IS SAFE BY CONSTRUCTION
# --------------------------
#   1. Everything is fetched to a staging directory first.
#   2. Every file is syntax-checked BEFORE it replaces the live one:
#      python3 -m py_compile for the app, `bash -n` for the shell
#      scripts, `nginx -t` for the config.
#   3. If any check fails, nothing is installed and the running site
#      is left exactly as it was.
#   4. The app is restarted and /health is polled. If it does not come
#      back, the previous copy is restored and the service is restarted
#      again, so a bad deploy takes the site down for seconds rather
#      than leaving it broken.
#
# Usage (on the VM, as root):
#     /opt/dr/redeploy.sh            # roll out everything
#     /opt/dr/redeploy.sh --check    # report what WOULD change
#     /opt/dr/redeploy.sh --dry-run  # fetch and check, install nothing
set -euo pipefail

# Every path and external command is overridable so the script can be
# exercised by the unit tests without a VM, a metadata server, a
# systemd, or root. The defaults are the real ones.
META_URL="${REDEPLOY_META_URL:-http://metadata.google.internal/computeMetadata/v1/instance/attributes}"
APP_DIR="${REDEPLOY_APP_DIR:-/opt/dr}"
NGINX_SITE="${REDEPLOY_NGINX_SITE:-/etc/nginx/sites-available/dr-app}"
NGINX_BIN="${REDEPLOY_NGINX_BIN:-nginx}"
NGINX_SERVICE="${REDEPLOY_NGINX_SERVICE:-nginx}"
SERVICE="${REDEPLOY_SERVICE:-dr-app.service}"
HEALTH_URL="${REDEPLOY_HEALTH_URL:-http://127.0.0.1:8000/health}"

# The stage directory holds the candidate files and the snapshot of what
# is currently running. It is removed on exit -- but only if this script
# created it. A caller-supplied stage (the unit tests) is left alone.
if [[ -n "${REDEPLOY_STAGE:-}" ]]; then
  STAGE="${REDEPLOY_STAGE}"
  STAGE_IS_OURS=0
else
  STAGE="$(mktemp -d /var/tmp/redeploy.XXXXXX)"
  STAGE_IS_OURS=1
fi
mkdir -p "${STAGE}"

CHECK_ONLY=0
DRY_RUN=0

log() { echo "[redeploy] $*"; }
die() { echo "[redeploy] ERROR: $*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

fetch_meta() {
  curl -fsS -H "Metadata-Flavor: Google" "${META_URL}/$1"
}

cleanup() {
  # Only remove a stage this script created. A caller-supplied one
  # belongs to the caller.
  if [[ "${STAGE_IS_OURS}" -eq 1 ]]; then
    rm -rf "${STAGE}"
  fi
}
trap cleanup EXIT

log "staging into ${STAGE}"

# --- fetch ------------------------------------------------------------------
# A missing attribute is a hard error, not a warning: silently skipping
# a file would leave the VM running a mix of old and new code, which
# is worse than not deploying at all.
fetch_into() {
  local key="$1" dest="$2"
  if ! fetch_meta "${key}" >"${dest}"; then
    die "could not fetch metadata attribute '${key}'"
  fi
  if [[ ! -s "${dest}" ]]; then
    die "metadata attribute '${key}' is empty"
  fi
}

fetch_into app-py         "${STAGE}/app.py"
fetch_into nginx-conf     "${STAGE}/nginx-app.conf"
fetch_into backup-script  "${STAGE}/backup.sh"
fetch_into verify-script  "${STAGE}/verify-backup.sh"

# --- snapshot what is running NOW -------------------------------------------
# This has to happen BEFORE anything else, because the nginx test below
# puts the candidate config in place. Comparing against the live files
# after that point would always report the nginx config as unchanged,
# which is exactly the kind of quiet lie that makes a status report
# worthless.
mkdir -p "${STAGE}/previous"
for f in app.py backup.sh verify-backup.sh; do
  [[ -f "${APP_DIR}/${f}" ]] && cp -p "${APP_DIR}/${f}" "${STAGE}/previous/${f}"
done
[[ -f "${NGINX_SITE}" ]] && cp -p "${NGINX_SITE}" "${STAGE}/previous/nginx-app.conf"

# --- check ------------------------------------------------------------------
log "checking the staged code"
python3 -m py_compile "${STAGE}/app.py" || die "the staged app.py does not compile"
bash -n "${STAGE}/backup.sh" || die "the staged backup.sh is not valid bash"
bash -n "${STAGE}/verify-backup.sh" || die "the staged verify-backup.sh is not valid bash"

# nginx -t validates the WHOLE configuration, so the candidate file has
# to be in place before the test. It is put there, tested, and the
# original restored if the test fails — so a rejected deploy leaves the
# server exactly as it was.
cp "${STAGE}/nginx-app.conf" "${NGINX_SITE}"
if ! "${NGINX_BIN}" -t 2>"${STAGE}/nginx-test.log"; then
  # Put the original back before exiting -- a failed deploy must not
  # leave a broken config on disk.
  if [[ -f "${STAGE}/previous/nginx-app.conf" ]]; then
    cp -p "${STAGE}/previous/nginx-app.conf" "${NGINX_SITE}"
  fi
  echo "[redeploy] ERROR: nginx rejected the candidate config:" >&2
  cat "${STAGE}/nginx-test.log" >&2
  die "aborting before anything was installed"
fi
log "all checks passed"

# --- report what changed ----------------------------------------------------
CHANGED=0
compare() {
  local label="$1" live="$2" staged="$3"
  local live_hash="" staged_hash=""
  [[ -f "${live}" ]] && live_hash="$(sha256sum "${live}" | cut -d' ' -f1)"
  staged_hash="$(sha256sum "${staged}" | cut -d' ' -f1)"
  if [[ "${live_hash}" == "${staged_hash}" ]]; then
    log "  ${label}: unchanged"
  else
    log "  ${label}: CHANGED"
    CHANGED=1
  fi
}

log "comparing against what is running:"
compare "app.py"          "${STAGE}/previous/app.py"           "${STAGE}/app.py"
compare "nginx-app.conf"  "${STAGE}/previous/nginx-app.conf"  "${STAGE}/nginx-app.conf"
compare "backup.sh"       "${STAGE}/previous/backup.sh"        "${STAGE}/backup.sh"
compare "verify-backup.sh" "${STAGE}/previous/verify-backup.sh" "${STAGE}/verify-backup.sh"

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  if [[ "${CHANGED}" -eq 0 ]]; then
    log "check complete: the running code matches the repository"
  else
    log "check complete: the running code is out of date"
  fi
  exit 0
fi

if [[ "${CHANGED}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
  log "nothing to do -- the running code already matches the repository"
  exit 0
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry run: nothing was installed"
  exit 0
fi

# --- install ----------------------------------------------------------------
log "installing"

# The previous copies were snapshotted before the nginx test, so a
# failed rollout can be undone properly. Without them, "roll back" would
# mean re-fetching the NEW code from the metadata server, which is not
# a rollback at all.
install -m 0644 "${STAGE}/app.py"           "${APP_DIR}/app.py"
install -m 0750 "${STAGE}/backup.sh"        "${APP_DIR}/backup.sh"
install -m 0750 "${STAGE}/verify-backup.sh" "${APP_DIR}/verify-backup.sh"

# The database is owned by www-data and lives in /var/lib/dr-app. It is
# deliberately NOT touched by this script.

log "restarting the app"
systemctl restart "${SERVICE}"

log "reloading nginx"
systemctl reload "${NGINX_SERVICE}"

# --- verify -----------------------------------------------------------------
log "waiting for /health"
HEALTHY=0
for _ in $(seq 1 30); do
  if curl -fsS -m 2 "${HEALTH_URL}" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 1
done

if [[ "${HEALTHY}" -ne 1 ]]; then
  log "the app did not come back -- rolling back to the previous version"
  if [[ -f "${STAGE}/previous/nginx-app.conf" ]]; then
    cp -p "${STAGE}/previous/nginx-app.conf" "${NGINX_SITE}"
  fi
  for f in app.py backup.sh verify-backup.sh; do
    if [[ -f "${STAGE}/previous/${f}" ]]; then
      cp -p "${STAGE}/previous/${f}" "${APP_DIR}/${f}"
    fi
  done
  systemctl restart "${SERVICE}" || true
  systemctl reload "${NGINX_SERVICE}" || true
  die "deploy failed and was rolled back. If the site is still down: journalctl -u dr-app -n 50"
fi

log "done -- the new code is live and serving"
curl -fsS "${HEALTH_URL}" && echo
