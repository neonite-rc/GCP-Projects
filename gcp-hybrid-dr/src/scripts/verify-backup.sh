#!/usr/bin/env bash
# Restore-drill helper: download the LATEST backup from the bucket, verify
# its checksum manifest, decompress and run a SQLite integrity check.
#
# Runs from an ADMIN workstation (or Cloud Shell), NOT from the primary VM:
# the VM's service account is deliberately write-only on the bucket
# (roles/storage.objectCreator), so it cannot list or read backups.
# "A backup you haven't restored is a hope, not a backup."
set -euo pipefail
umask 077

BACKUP_BUCKET="${1:-${BACKUP_BUCKET:-}}"
BACKUP_PREFIX="${BACKUP_PREFIX:-backups}"

if [[ -z "${BACKUP_BUCKET}" ]]; then
  echo "usage: $0 <backup-bucket-name>" >&2
  exit 2
fi
if [[ ! "${BACKUP_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]]; then
  echo "ERROR: invalid bucket name: ${BACKUP_BUCKET}" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# Timestamped names sort lexicographically == chronologically.
LATEST="$(gcloud storage ls "gs://${BACKUP_BUCKET}/${BACKUP_PREFIX}/app-*.db.gz" | sort | tail -n 1)"
if [[ -z "${LATEST}" ]]; then
  echo "ERROR: no backups found in gs://${BACKUP_BUCKET}/${BACKUP_PREFIX}/" >&2
  exit 1
fi
echo "latest backup: ${LATEST}"

gcloud storage cp "${LATEST}" "${LATEST}.sha256" "${WORKDIR}/"

BASENAME="$(basename "${LATEST}")"
(cd "${WORKDIR}" && sha256sum -c "${BASENAME}.sha256")

gunzip -t "${WORKDIR}/${BASENAME}"
gunzip "${WORKDIR}/${BASENAME}"

DB_FILE="${WORKDIR}/${BASENAME%.gz}"
INTEGRITY="$(sqlite3 "${DB_FILE}" 'PRAGMA integrity_check;')"
if [[ "${INTEGRITY}" != "ok" ]]; then
  echo "ERROR: integrity_check failed: ${INTEGRITY}" >&2
  exit 1
fi

ROWS="$(sqlite3 "${DB_FILE}" 'SELECT count(*) FROM orders;')"
echo "OK: checksum verified, gzip intact, integrity_check ok, ${ROWS} order rows"

# Report backup age against the RPO target so a drill doubles as an RPO spot
# check (the Cloud Function does this continuously).
FILE_TS="${BASENAME#app-}"
FILE_TS="${FILE_TS%.db.gz}"
BACKUP_EPOCH="$(date -u -d "${FILE_TS:0:4}-${FILE_TS:4:2}-${FILE_TS:6:2} ${FILE_TS:9:2}:${FILE_TS:11:2}:${FILE_TS:13:2}" +%s)"
NOW_EPOCH="$(date -u +%s)"
AGE_HOURS=$(((NOW_EPOCH - BACKUP_EPOCH) / 3600))
echo "backup age: ${AGE_HOURS}h (RPO target: <24h)"
if ((AGE_HOURS >= 24)); then
  echo "WARNING: RPO target breached" >&2
  exit 1
fi
