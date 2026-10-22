#!/usr/bin/env bash
# Stub `curl` used by the backup.sh tests.
#
# It understands the one Cloud Storage JSON API call the script makes:
#
#   POST .../upload/storage/v1/b/<bucket>/o?uploadType=multipart
#   Content-Type: multipart/related; boundary=dr-backup-boundary
#
# The behaviour that matters: it VALIDATES the `crc32c` metadata field
# exactly as Cloud Storage does. A mismatched checksum is rejected with
# a 400, and so is an upload whose metadata is missing the field the
# script is supposed to send. A stub that accepted anything would have
# let a broken checksum ship — which is exactly what happened once.
set -euo pipefail

CAPTURE="${DR_TEST_CAPTURE:?}"
BUCKET="${DR_TEST_BUCKET:-test-bucket}"

if [[ "${1:-}" == "-sS" && "${2:-}" == "-X" && "${3:-}" == "POST" ]]; then
  shift 3
  BODY_FILE=""
  URL=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data-binary)
        BODY_FILE="${2#@}"
        shift 2
        ;;
      --data-binary=*)
        BODY_FILE="${1#--data-binary=}"
        BODY_FILE="${BODY_FILE#@}"
        shift
        ;;
      -H) shift 2 ;;
      -H*) shift ;;
      http*) URL="$1"; shift ;;
      *) shift ;;
    esac
  done

  python3 "${DR_TEST_STUB_PY}" "${BODY_FILE}" "${BUCKET}" "${CAPTURE}"
  exit 0
fi

exec /usr/bin/curl "$@"
