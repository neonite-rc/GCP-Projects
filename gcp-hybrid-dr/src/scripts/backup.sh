#!/usr/bin/env bash
# Nightly backup: SQLite online backup -> gzip -> checksum manifest ->
# upload to the CMEK-encrypted backup bucket.
#
# Design notes (see docs/03-security.md):
# - The VM's service account holds ONLY roles/storage.objectCreator on the
#   backup bucket (bucket-level). It can write new objects but cannot list,
#   read, overwrite or delete — a ransomware operator on this VM cannot
#   destroy existing backups. Consequence: remote re-verification happens
#   OFF this VM (verify-backup.sh from an admin workstation, plus the
#   freshness-check Cloud Function).
# - Encryption at rest is the bucket's default CMEK key (Cloud KMS); the
#   GCS service agent encrypts server-side, so no key material or flags
#   are needed here.
#
# WHY NOT `gcloud storage cp`?
# ------------------------------
# `gcloud storage cp` READS the destination object before writing it (to
# decide whether to overwrite). That read needs `storage.objects.get`,
# which roles/storage.objectCreator does NOT grant — so the upload fails
# with HTTP 403 "does not have storage.objects.get access".
#
# Granting the read would mean giving the primary VM permission to read
# existing backups, which breaks the one property this whole design
# depends on: a compromised primary must not be able to read or tamper
# with its own recovery path.
#
# So the upload goes through the Cloud Storage JSON API's
# `uploadType=media` endpoint, which CREATES the object without reading
# the destination first. It also lets us send `x-goog-hash: crc32c=...`,
# so GCS still validates the payload's checksum in transit and returns
# 400 on corruption — the same guarantee `gcloud storage cp` gives.
#
# Idempotent: timestamped object names, a run lock, and a temp workdir
# cleaned on every exit path. Re-running only ever adds a new backup.
set -euo pipefail
umask 077

ENV_FILE="${DR_BACKUP_ENV:-/etc/dr-backup.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET not set (see /etc/dr-backup.env)}"
DB_PATH="${DB_PATH:?DB_PATH not set (see /etc/dr-backup.env)}"
BACKUP_PREFIX="${BACKUP_PREFIX:-backups}"
LOCK_FILE="${LOCK_FILE:-/var/run/dr-backup.lock}"

# Validate inputs used to build paths/URLs: bucket names are lowercase
# letters, digits, dashes, underscores and dots.
if [[ ! "${BACKUP_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]]; then
  echo "ERROR: invalid bucket name: ${BACKUP_BUCKET}" >&2
  exit 1
fi
if [[ ! -r "${DB_PATH}" ]]; then
  echo "ERROR: database not readable: ${DB_PATH}" >&2
  exit 1
fi

# Single-runner lock: a slow upload at 02:00 must not race a manual run.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "ERROR: another backup is already running" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# upload <local-file> <object-name>
#
# Uploads via the Cloud Storage JSON API, which creates the object
# without reading the destination first — the only upload path that
# works with a write-only objectCreator binding.
#
# INTEGRITY: the checksum goes in the request METADATA as the `crc32c`
# field, not as an `x-goog-hash` header. The difference matters:
#
#   * the `crc32c` metadata field IS validated. Send a wrong one and
#     GCS rejects the upload:
#         Provided CRC32C "AAAAAA==" doesn't match calculated CRC32C ...
#   * the `x-goog-hash: crc32c=` header is NOT validated — GCS accepts
#     a wrong checksum in the header and silently ignores it.
#
# (Both behaviours were measured against the live bucket; see
# docs/06-measurements.md.)
#
# And the algorithm is CRC32C (Castagnoli, polynomial 0x82F63B78), NOT
# zlib's crc32 (IEEE 802.3, polynomial 0xEDB88320). They are different
# functions with different values, and Python's stdlib has no CRC32C —
# so it is implemented here. Verified against the standard check
# vector: crc32c("123456789") == 0xe3069283.
# ---------------------------------------------------------------------------
upload() {
  local local_file="$1" object_name="$2"
  local token crc metadata payload encoded response

  token="$(gcloud auth application-default print-access-token 2>/dev/null | tail -n 1)"
  if [[ -z "${token}" ]]; then
    echo "ERROR: could not obtain an access token for the VM's service account" >&2
    return 1
  fi

  # CRC32C as base64, the encoding the API expects.
  crc="$(python3 - "${local_file}" <<'PY'
import base64, sys

# CRC32C (Castagnoli) — the algorithm Cloud Storage validates.
_POLY = 0x82F63B78
_TABLE = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (_POLY if _c & 1 else 0)
    _TABLE.append(_c)


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc = _TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


with open(sys.argv[1], "rb") as fh:
    data = fh.read()

print(base64.b64encode(crc32c(data).to_bytes(4, "big")).decode())
PY
)"

  if [[ -z "${crc}" ]]; then
    echo "ERROR: could not compute the CRC32C of ${local_file}" >&2
    return 1
  fi

  # Object names are URL-encoded; the only characters that can appear are
  # the timestamp, dots and the fixed extension, so encoding is trivial
  # but still done explicitly rather than assumed.
  encoded="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${object_name}")"

  # The metadata is sent as a multipart body, so the checksum is a real
  # validated field rather than a header GCS ignores.
  metadata="{\"name\":\"${encoded}\",\"crc32c\":\"${crc}\"}"
  payload="$(mktemp)"
  {
    printf -- '--dr-backup-boundary\r\n'
    printf 'Content-Type: application/json; charset=UTF-8\r\n\r\n'
    printf '%s\r\n' "${metadata}"
    printf -- '--dr-backup-boundary\r\n'
    printf 'Content-Type: application/octet-stream\r\n\r\n'
    cat "${local_file}"
    printf '\r\n--dr-backup-boundary--\r\n'
  } >"${payload}"

  response="$(curl -sS -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: multipart/related; boundary=dr-backup-boundary" \
    --data-binary "@${payload}" \
    "https://storage.googleapis.com/upload/storage/v1/b/${BACKUP_BUCKET}/o?uploadType=multipart")"
  rm -f "${payload}"

  if ! grep -q '"kind"[[:space:]]*:[[:space:]]*"storage#object"' <<<"${response}"; then
    echo "ERROR: upload of ${object_name} failed: ${response}" >&2
    return 1
  fi
  echo "uploaded gs://${BACKUP_BUCKET}/${object_name} (crc32c ${crc})"
}

# Timestamp for the object name. MILLISECOND precision on purpose: the
# name is the primary sort key for "newest backup" (the restore drill and
# verify-backup.sh both rely on lexicographic order == chronological
# order), so the format must stay fixed-width.
#
# Why not seconds? Two runs inside the same second would produce the
# SAME object name. The primary VM's service account holds only
# roles/storage.objectCreator, which is deliberately WRITE-ONLY and
# therefore CANNOT overwrite an existing object — the second upload would
# fail and take the whole backup down with it. Millisecond precision
# makes accidental collisions impossible while keeping the name sortable
# and still parseable by verify-backup.sh (which reads the first 15
# characters).
TS="$(date -u +%Y%m%dT%H%M%S.%3NZ)"
BASENAME="app-${TS}.db"

echo "[$(date -u --iso-8601=seconds)] backup starting: ${DB_PATH} -> gs://${BACKUP_BUCKET}/${BACKUP_PREFIX}/"

# 1. Consistent snapshot via SQLite's online backup API — safe while the
#    app is serving traffic (no Apache/nginx stop needed, unlike the
#    original plan; documented in JOURNEY.md Day 3).
sqlite3 "${DB_PATH}" ".backup '${WORKDIR}/${BASENAME}'"

# 2. Verify the snapshot BEFORE shipping it — a corrupt backup discovered
#    during a disaster is not a backup.
INTEGRITY="$(sqlite3 "${WORKDIR}/${BASENAME}" 'PRAGMA integrity_check;')"
if [[ "${INTEGRITY}" != "ok" ]]; then
  echo "ERROR: integrity_check failed: ${INTEGRITY}" >&2
  exit 1
fi

# 3. Compress + checksum manifest (sha256 of the compressed artifact).
gzip -9 "${WORKDIR}/${BASENAME}"
(cd "${WORKDIR}" && sha256sum "${BASENAME}.gz" >"${BASENAME}.gz.sha256")

# 4. Upload artifact then manifest. GCS validates CRC32C en route;
#    any mismatch or permission failure aborts the whole backup.
upload "${WORKDIR}/${BASENAME}.gz" "${BACKUP_PREFIX}/${BASENAME}.gz"
upload "${WORKDIR}/${BASENAME}.gz.sha256" "${BACKUP_PREFIX}/${BASENAME}.gz.sha256"

echo "[$(date -u --iso-8601=seconds)] backup complete: ${BASENAME}.gz"
