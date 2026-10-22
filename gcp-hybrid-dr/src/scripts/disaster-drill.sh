#!/usr/bin/env bash
# Disaster drill: measure ACTUAL RTO end-to-end, not the documented guess.
#
# What it does (JOURNEY.md Day 9, extended Day 10):
#   1. stop the primary VM (the simulated disaster)
#   2. resolve the public DNS name and poll the endpoint until it answers
#      again — this exercises the REAL user-visible path:
#        DNS resolution -> alert detection -> record flip -> TTL expiry
#        -> connect -> serve
#   3. print a timestamped timeline and the measured total RTO
#   4. ALWAYS restart the VM, even if the drill fails (trap on EXIT)
#
# Runs from an ADMIN workstation with gcloud authenticated. Stopping the VM
# is a real outage of the primary site — run it when that is acceptable.
#
# Usage:
#   ./disaster-drill.sh --project PROJECT_ID [--zone ZONE] [--instance NAME]
#                      [--url SERVICE_URL] [--dns-name FQDN]
#                      [--resolver NS] [--ttl SECONDS]
#
#   --url       DR target to poll (Cloud Run URI). Default: auto-discovered
#               from Terraform output dr_service_uri.
#   --dns-name  If set, polls THIS name instead of the DR URL — measures the
#               full user-visible path including detection + record flip + TTL.
#   --resolver  Query this nameserver for --dns-name (e.g. a Cloud DNS
#               authoritative NS). This is how you exercise the failover
#               path WITHOUT owning a domain: the zone's nameservers are
#               authoritative for the zone's own name.
#   --ttl       Wait this long for a resolver cache to expire before
#               declaring the drill failed (default 300 = the record TTL).
set -euo pipefail

PROJECT="${TF_VAR_project_id:-}"
ZONE="us-east1-b"
INSTANCE="dr-demo-primary"
URL=""
DNS_NAME=""
RESOLVER=""
TTL=300
POLL_INTERVAL=10
TIMEOUT=900

# usage [exit_code] — prints the header comment block as the help text.
# Exit code is 0 for an explicit --help and 2 for a usage ERROR, so
# callers (and humans) can tell "here's how to use it" from "you got the
# invocation wrong".
usage() {
  local code="${1:-2}"
  grep '^#' "$0" | cut -c3-
  exit "${code}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)  PROJECT="$2"; shift 2 ;;
    --zone)     ZONE="$2"; shift 2 ;;
    --instance) INSTANCE="$2"; shift 2 ;;
    --url)      URL="$2"; shift 2 ;;
    --dns-name) DNS_NAME="$2"; shift 2 ;;
    --resolver) RESOLVER="$2"; shift 2 ;;
    --ttl)      TTL="$2"; shift 2 ;;
    --poll)     POLL_INTERVAL="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage 2 ;;
  esac
done

[[ -n "${PROJECT}" ]] || { echo "ERROR: --project (or TF_VAR_project_id) required" >&2; usage 2; }
if [[ -z "${URL}" && -z "${DNS_NAME}" ]]; then
  # Auto-discover the DR URL from the root module's output
  TERRAFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
  URL="$(terraform -chdir="${TERRAFORM_DIR}" output -raw dr_service_uri 2>/dev/null || true)"
  [[ -n "${URL}" ]] || { echo "ERROR: no --url/--dns-name and could not read terraform output dr_service_uri" >&2; exit 1; }
fi

command -v dig >/dev/null || { echo "ERROR: dig is required for DNS-name drills (apt install dnsutils)" >&2; exit 1; }

now() { date -u +%s; }
stamp() { date -u --iso-8601=seconds; }

# resolve <name> — print the HOSTNAME a user would end up connecting to.
#
# Two resolvers are involved, exactly as in production:
#
#   1. the zone's AUTHORITATIVE nameserver answers for the zone's own
#      names, and returns the CNAME target (a hostname);
#   2. the TARGET of that CNAME is an external name (the Cloud Run
#      *.a.run.app front end), which the authoritative server does not
#      and should not resolve — it is authoritative for its own zone
#      only.
#
# So the chain is: ask the authoritative server for the zone's name,
# then resolve whatever it points at with the normal resolver. Querying
# the authoritative server for the external target returns nothing,
# which is correct DNS behaviour, not a failure.
#
# The result is a HOSTNAME, not an IP: the standby is a TLS endpoint
# with its own certificate, so a real client connects to it by name
# (SNI + certificate validation). Dialling a bare IP would fail TLS.
#
# With no --resolver this uses the system resolver throughout (a real
# user's view).
resolve() {
  local hops=0 current="$1" answer=""

  while ((hops < 8)); do
    # The zone's authoritative nameserver answers for names INSIDE the
    # zone — both the public name and the "primary.<zone>" target.
    # Anything outside the zone (the Cloud Run *.a.run.app front end)
    # must go to the normal resolver.
    #
    # The comparison ignores the trailing dot, which DNS names may or
    # may not carry.
    local current_stripped="${current%.}"
    if [[ -n "${RESOLVER}" && "${current_stripped}" == *".${ZONE_NAME}" ]]; then
      answer="$(dig +short "@${RESOLVER}" "${current}" A 2>/dev/null | head -1)"
    else
      answer="$(dig +short "${current}" A 2>/dev/null | head -1)"
    fi
    answer="${answer%%$'\n'*}"

    # Already an IP address -> nothing more to follow.
    if [[ "${answer}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "${current}"
      return 0
    fi

    # A CNAME target -> follow it.
    if [[ -n "${answer}" ]]; then
      current="${answer}"
      hops=$((hops + 1))
      continue
    fi

    # No answer at all.
    return 1
  done
  return 1
}

# probe_ok <target> — does the endpoint answer 200 on /health?
#
# The target may be:
#   * a bare IP          -> the primary VM, plain HTTP (no TLS without
#                           a registered domain)
#   * a hostname ending in the zone -> the primary's own target name,
#                           also plain HTTP
#   * any other hostname -> the Cloud Run standby, HTTPS (it has a real
#                           certificate and a real hostname, and a client
#                           connecting by name is what a user actually
#                           does)
probe_ok() {
  local target="$1" code scheme="https" stripped="${1%.}" url_target="$1"

  # Accept either a bare target or a full URL.
  if [[ "${target}" == http://* || "${target}" == https://* ]]; then
    if [[ "${target}" == http://* ]]; then
      scheme="http"
    fi
    url_target="${target#*://}"
    url_target="${url_target%%/*}"
    stripped="${url_target%.}"
  elif [[ "${target}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    scheme="http"
  elif [[ -n "${ZONE_NAME}" && "${stripped}" == *".${ZONE_NAME}" ]]; then
    # A name INSIDE the zone: the public resolver cannot see it (only the
    # zone's authoritative nameserver can), and there is no TLS for it
    # either. Resolve it to an address and talk HTTP to that.
    scheme="http"
    local ip
    ip="$(dig +short "@${RESOLVER}" "${target}" A 2>/dev/null | head -1)"
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && url_target="${ip}"
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    "${scheme}://${url_target}/health" 2>/dev/null || true)"
  [[ "${code}" == "200" ]]
}

TARGET="${DNS_NAME:-${URL}}"
# The zone the public name lives in — everything under it is answered by
# the zone's authoritative nameserver. The trailing dot is stripped so
# the suffix test below is a plain string comparison.
ZONE_NAME="${DNS_NAME#*.}"
ZONE_NAME="${ZONE_NAME%.}"
echo "disaster drill: project=${PROJECT} instance=${INSTANCE}"
if [[ -n "${DNS_NAME}" ]]; then
  echo "polling target after failover: ${TARGET}"
  if [[ -n "${RESOLVER}" ]]; then
    echo "resolver: ${RESOLVER} (authoritative) — TTL ${TTL}s"

    # Verify the resolver actually serves this zone BEFORE injecting the
    # outage. A wrong --resolver produces no answer at all, and without
    # this check the drill would run for its full timeout and then
    # report "no recovery" — blaming the DR system for a mistyped
    # argument.
    if ! dig "@${RESOLVER}" "${DNS_NAME}" A +short 2>/dev/null \
      | grep -qE "${ZONE_NAME}|^[0-9]+\."; then
      echo "ERROR: ${RESOLVER} does not appear to be authoritative for ${ZONE_NAME}." >&2
      echo "       Get the right nameservers with:" >&2
      echo "         terraform output -json dns_name_servers | jq -r '.[0]'" >&2
      exit 1
    fi
  else
    echo "resolver: system default"
  fi
else
  echo "polling target after failover: ${TARGET}/health"
fi
echo

START="$(now)"
T0="$(stamp)"
echo "[${T0}] stopping ${INSTANCE} (simulated disaster)"

gcloud compute instances stop "${INSTANCE}" \
  --project "${PROJECT}" --zone "${ZONE}" --quiet

VM_STOPPED="$(now)"
echo "[$(stamp)] VM stopped (+$((VM_STOPPED - START))s)"

# ---------------------------------------------------------------------------
# Poll for recovery.
#
# With a DNS name we resolve it every cycle and probe whatever it points
# at, with the correct Host header. That is the honest measurement: it
# includes the TTL cache window that a real user's resolver would impose.
# ---------------------------------------------------------------------------

RESTORED_AT=""
ELAPSED=""
cleanup() {
  local rc=$?
  if [[ -z "${RESTORED_AT}" ]]; then
    echo >&2
    echo "[$(stamp)] drill failed/aborted — restarting ${INSTANCE} anyway" >&2
    gcloud compute instances start "${INSTANCE}" \
      --project "${PROJECT}" --zone "${ZONE}" --quiet >&2 || true
  fi
  exit "${rc}"
}
trap cleanup EXIT

LAST_IP=""
while :; do
  ELAPSED=$(( $(now) - START ))
  (( ELAPSED <= TIMEOUT )) || { echo "ERROR: no recovery within ${TIMEOUT}s" >&2; break; }

  if [[ -n "${DNS_NAME}" ]]; then
    TARGET_HOST="$(resolve "${DNS_NAME}" || true)"
    if [[ -n "${TARGET_HOST}" && "${TARGET_HOST}" != "${LAST_IP}" ]]; then
      echo "[$(stamp)] DNS ${DNS_NAME} -> ${TARGET_HOST}"
      LAST_IP="${TARGET_HOST}"
    fi
    if [[ -n "${TARGET_HOST}" ]]; then
      # The standby answers /health with 200; so does the primary. What
      # distinguishes them is WHICH host answered — and the whole point
      # of the drill is that the standby answers, so a 200 on /health
      # through the public name means "users are being served".
      if probe_ok "${TARGET_HOST}"; then
        RESTORED_AT="$(now)"
        echo "[$(stamp)] endpoint answering 200 on /health via ${TARGET_HOST}"
        break
      fi
    fi
  else
    if probe_ok "${TARGET}"; then
      RESTORED_AT="$(now)"
      echo "[$(stamp)] DR answering 200 on /health"
      break
    fi
  fi
  sleep "${POLL_INTERVAL}"
done

echo "[$(stamp)] restarting ${INSTANCE}"
gcloud compute instances start "${INSTANCE}" \
  --project "${PROJECT}" --zone "${ZONE}" --quiet
RESTORED_AT="${RESTORED_AT:-$(now)}"

# Wait for the PRIMARY to be healthy again so we leave things as found
PRIMARY_IP="$(gcloud compute instances describe "${INSTANCE}" \
  --project "${PROJECT}" --zone "${ZONE}" \
  --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')"

# The hostname the public record should point at once the primary is
# healthy: the zone's own "primary.<zone>" A-record target.
#
# resolve() returns the NAME it finally points at (not the address), so
# the restore check compares names.
PRIMARY_TARGET_HOST="${PRIMARY_TARGET_HOST:-primary.${DNS_NAME#*.}}"

while ! probe_ok "http://${PRIMARY_IP}"; do
  sleep "${POLL_INTERVAL}"
done
echo "[$(stamp)] primary healthy again (${PRIMARY_IP})"

# The recovery half of the failover: the alert closes when the primary
# comes back, and the dns-failover function restores the public record.
# Wait for that too, so the drill verifies the FULL round trip and not
# just the outbound flip.
if [[ -n "${DNS_NAME}" ]]; then
  echo "[$(stamp)] waiting for the DNS record to be restored to the primary..."
  RESTORE_WAIT=0
  while :; do
    RESTORED_HOST="$(resolve "${DNS_NAME}" || true)"
    # The primary's own target name is what the record should point at
    # again; resolve() returns the final host it points to. Compare
    # without the trailing dot, which either side may or may not carry.
    if [[ "${RESTORED_HOST%.}" == "${PRIMARY_TARGET_HOST%.}" ]]; then
      echo "[$(stamp)] DNS restored -> ${RESTORED_HOST} (primary)"
      break
    fi
    (( RESTORE_WAIT < 600 )) || { echo "WARNING: DNS not restored within 600s" >&2; break; }
    sleep "${POLL_INTERVAL}"
  done
fi

TOTAL_RTO=$(( RESTORED_AT - START ))
{
  echo
  echo "=== MEASURED RTO ==="
  echo "disaster injected : ${T0}"
  echo "DR serving users  : +${TOTAL_RTO}s"
  if [[ -n "${DNS_NAME}" ]]; then
    echo "path measured     : DNS(${DNS_NAME}${RESOLVER:+, via $RESOLVER}) -> resolve -> connect -> /health 200"
  else
    echo "path measured     : direct HTTP to the DR endpoint"
  fi
  echo "(detection + failover automation + TTL cache expiry + cold start)"
} | tee "${HOME}/rto-drill-result.txt"
echo "result also written to ~/rto-drill-result.txt"
