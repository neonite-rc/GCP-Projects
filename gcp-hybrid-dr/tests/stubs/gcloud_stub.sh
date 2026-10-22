#!/usr/bin/env bash
# Stub `gcloud` used by the backup.sh / verify-backup.sh tests.
#
# It emulates the handful of `gcloud storage` subcommands the scripts
# use, against a local directory that stands in for the bucket:
#
#   gcloud storage ls  gs://bucket/prefix/app-*.db.gz
#   gcloud storage cp  SRC [SRC...] gs://bucket/prefix/NAME
#   gcloud auth application-default print-access-token
#
# The environment variables DR_TEST_CAPTURE and DR_TEST_BUCKET point at
# the capture directory and the bucket name.
set -euo pipefail

CAPTURE="${DR_TEST_CAPTURE:?}"
BUCKET="${DR_TEST_BUCKET:-test-bucket}"

if [[ "${1:-}" == "auth" ]]; then
  echo "fake-access-token"
  exit 0
fi

if [[ "${1:-}" == "storage" && "${2:-}" == "ls" ]]; then
  URL="${3:-}"
  REL="${URL#gs://}"
  DIR="$(dirname "${REL}")"
  PATTERN="$(basename "${REL}")"
  ROOT="${CAPTURE}/${DIR}"

  if [[ -d "${ROOT}" ]]; then
    # The pattern is a GLOB, so translate it to a regex rather than
    # handing it to grep -E, where '*' is a quantifier and
    # "app-*.db.gz" would not match the literal object name.
    REGEX="$(printf '%s' "${PATTERN}" | sed -e 's/[][\\.^$+?(){}|]/\\&/g' -e 's/\*/.*/g')"
    (cd "${ROOT}" && ls -1 2>/dev/null | grep -E "^${REGEX}$" | sed "s|^|${URL%/*}/|") || true
  fi
  exit 0
fi

if [[ "${1:-}" == "storage" && "${2:-}" == "cp" ]]; then
  shift 2
  ARGS=("$@")
  DEST="${ARGS[-1]}"
  SOURCES=("${ARGS[@]:0:${#ARGS[@]}-1}")

  for src in "${SOURCES[@]}"; do
    if [[ "${src}" == gs://* ]]; then
      SRC="${CAPTURE}/${src#gs://}"
    else
      SRC="${src}"
    fi
    if [[ "${DEST}" == gs://* ]]; then
      OUT="${CAPTURE}/${DEST#gs://}"
    else
      OUT="${DEST}/$(basename "${SRC}")"
    fi
    mkdir -p "$(dirname "${OUT}")"
    cp "${SRC}" "${OUT}"
  done
  exit 0
fi

echo "stub gcloud: unsupported command: $*" >&2
exit 1
