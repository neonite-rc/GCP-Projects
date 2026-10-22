#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time bootstrap for the Terraform remote state bucket.
#
#   ./scripts/bootstrap-state.sh <PROJECT_ID> [REGION]
#
# Creates a versioned, CMEK-free (default encryption), uniformly-locked
# GCS bucket for terraform state, then prints the init command.
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_ID="${1:?usage: bootstrap-state.sh <PROJECT_ID> [REGION]}"
REGION="${2:-us-east1}"
BUCKET="${PROJECT_ID}-tfstate"

if ! command -v gcloud >/dev/null; then
  echo "error: gcloud CLI not found" >&2
  exit 1
fi

echo "==> Creating state bucket gs://${BUCKET} (${REGION})"
gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access \
  --public-access-prevention \
  --default-storage-class=STANDARD

echo "==> Enabling object versioning (every apply keeps its prior state)"
gcloud storage buckets update "gs://${BUCKET}" --versioning

# Cap noncurrent state-version buildup: keep 30 days of history.
LIFECYCLE="$(mktemp)"
trap 'rm -f "${LIFECYCLE}"' EXIT
cat >"${LIFECYCLE}" <<'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"daysSinceNoncurrentTime": 30}
    }
  ]
}
EOF
gcloud storage buckets update "gs://${BUCKET}" --lifecycle-file="${LIFECYCLE}"

echo "==> Labeling"
gcloud storage buckets update "gs://${BUCKET}" \
  --update-labels=project=gcp-hybrid-dr,managed-by=terraform,purpose=tfstate

cat <<EOF

Done. Initialise Terraform against it:

  cd terraform
  terraform init -backend-config="bucket=${BUCKET}"

State is now versioned server-side: any destructive change can be rolled
back from a prior object version.
EOF
