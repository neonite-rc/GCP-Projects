# ---------------------------------------------------------------------------
# Remote state — GCS backend with object versioning (survives local machine
# loss, every prior state version retained).
#
# The bucket name is intentionally NOT hardcoded here: this is a partial
# configuration, supplied at init time so the repo stays project-agnostic:
#
#   ../scripts/bootstrap-state.sh        # one-time: creates the state bucket
#   terraform init \
#     -backend-config="bucket=<STATE_BUCKET>"
#
# Versioning on the bucket means every `terraform apply` keeps its prior
# state object — a destructive change is always recoverable.
# ---------------------------------------------------------------------------
terraform {
  backend "gcs" {
    prefix = "gcp-hybrid-dr"
  }
}
