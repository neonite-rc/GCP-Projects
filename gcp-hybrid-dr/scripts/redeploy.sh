#!/usr/bin/env bash
# Ship the current code in src/ to the running primary site.
#
# The primary's code is delivered through instance metadata, and
# startup.sh fetches it once at first boot. That means `terraform
# apply` updates the metadata but does NOT change what the VM is
# running -- and restarting the VM does not help either, because the
# provisioning marker makes startup.sh exit immediately.
#
# This wrapper is the missing operation. It:
#
#   1. checks that the firewall still allows YOUR IP to reach SSH
#      (a residential IP changes, and the rule is admin-IP-only)
#   2. asks the VM to run src/scripts/redeploy.sh, which is itself
#      fetched from the metadata server -- so the script that runs is
#      always the one in the repository, never a stale local copy
#
# The remote script validates everything before it installs anything,
# and rolls back if the app does not come back. The database is never
# touched.
#
# Usage:
#     scripts/redeploy.sh                 # roll out
#     scripts/redeploy.sh --check         # report what would change
#     scripts/redeploy.sh --dry-run       # fetch and check, install nothing
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${GCP_PROJECT:-gcp-hybrid-dr}"
ZONE="${GCP_ZONE:-us-east1-b}"
INSTANCE="${GCP_INSTANCE:-dr-demo-primary}"

log() { echo "[redeploy] $*"; }
die() { echo "[redeploy] ERROR: $*" >&2; exit 1; }

# The script to run on the VM is delivered through the same metadata
# channel as the rest of the code, so there is exactly one copy of it
# and it is the one in the repository.
REMOTE_COMMAND="curl -fsS -H 'Metadata-Flavor: Google' \
http://metadata.google.internal/computeMetadata/v1/instance/attributes/redeploy-script \
| sudo bash -s --"

run_on_vm() {
  local extra_args="$1"
  gcloud compute ssh "${INSTANCE}" \
    --zone "${ZONE}" \
    --project "${PROJECT}" \
    --quiet \
    --command "${REMOTE_COMMAND} ${extra_args}"
}

# --- preflight: can we even reach the VM? ----------------------------------
# The SSH rule allows one IP: yours. A residential IP changes without
# notice, and the failure mode is a confusing "connection timed out"
# rather than "your IP changed". Say so explicitly.
check_ssh_reachable() {
  local my_ip allowed
  my_ip="$(curl -4 -s --max-time 10 https://ifconfig.me || echo "unknown")"
  allowed="$(gcloud compute firewall-rules list \
    --project "${PROJECT}" \
    --filter="name~allow-ssh-admin" \
    --format="value(sourceRanges.list())" 2>/dev/null | head -1)"

  if [[ "${allowed}" != *"${my_ip}"* ]]; then
    log "your public IPv4 is ${my_ip}, but the SSH firewall rule allows ${allowed}."
    log "The admin-IP-only rule is doing its job, and a residential IP is not static."
    log ""
    log "Fix it with:"
    log "  sed -i 's|^admin_ip_cidr = .*|admin_ip_cidr = \"${my_ip}/32\"|' terraform/terraform.tfvars"
    log "  (cd terraform && env GOOGLE_CLOUD_QUOTA_PROJECT=${PROJECT} terraform apply -auto-approve)"
    log ""
    die "cannot reach the VM over SSH until the firewall rule is updated"
  fi
  log "SSH reachable from ${my_ip}"
}

# --- preflight: has the code actually been pushed to the metadata? ---------
# redeploy.sh reads the code from the metadata server, so if the
# repository's code has not been applied yet, this would redeploy the
# OLD code and report "nothing to do" -- a confusing outcome.
check_metadata_is_current() {
  local local_hash remote_hash
  local_hash="$(sha256sum "${REPO_ROOT}/src/app/app.py" | cut -d' ' -f1)"

  # The metadata attribute holds the file contents; hashing what the VM
  # would download is the only way to compare without pulling it.
  remote_hash="$(
    gcloud compute instances describe "${INSTANCE}" \
      --zone "${ZONE}" --project "${PROJECT}" --format=json 2>/dev/null \
      | python3 -c "
import json,sys,hashlib
d=json.load(sys.stdin)
items={i['key']:i['value'] for i in d.get('metadata',{}).get('items',[])}
v=items.get('app-py','')
print(hashlib.sha256(v.encode()).hexdigest())
"
  )"

  if [[ -n "${remote_hash}" && "${remote_hash}" != "${local_hash}" ]]; then
    log "the repository's app.py differs from what is in the instance metadata."
    log "Apply Terraform first, or the redeploy would ship the old code:"
    log "  (cd terraform && env GOOGLE_CLOUD_QUOTA_PROJECT=${PROJECT} terraform apply -auto-approve)"
    die "metadata is out of date"
  fi
  log "instance metadata matches the repository"
}

case "${1:-}" in
  --check)
    check_ssh_reachable
    check_metadata_is_current
    run_on_vm "--check"
    ;;
  --dry-run)
    check_ssh_reachable
    check_metadata_is_current
    run_on_vm "--dry-run"
    ;;
  "")
    check_ssh_reachable
    check_metadata_is_current
    run_on_vm ""
    ;;
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    die "unknown argument: $1 (try --help)"
    ;;
esac
