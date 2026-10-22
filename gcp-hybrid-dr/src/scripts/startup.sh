#!/usr/bin/env bash
# Startup script for the simulated on-prem primary site (e2-micro).
# Idempotent: a marker file guards the whole provisioning block, so VM
# reboots don't re-run apt or clobber the live database.
#
# App code, nginx config and backup scripts are delivered via instance
# metadata (single source of truth: the files in src/), fetched from the
# metadata server at first boot — no duplication inside this script.
set -euo pipefail

MARKER=/var/lib/dr-primary/.provisioned
if [[ -f "${MARKER}" ]]; then
  echo "dr-primary: already provisioned, exiting"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx python3-flask gunicorn sqlite3 cron \
  unattended-upgrades curl ca-certificates apt-transport-https

# The Google Cloud CLI, from Google's own apt repository. Installing it
# from the distro repo is not an option — Debian does not package gcloud.
#
# This is NOT optional: backup.sh uploads through the Cloud Storage JSON
# API using `gcloud auth application-default print-access-token`, and
# the base `debian-cloud/debian-12` image does NOT ship the gcloud CLI
# (only the `debian-12-gce` variant does). Without this package the
# hourly backup fails at the token step.
if ! command -v gcloud >/dev/null 2>&1; then
  echo "==> installing the Google Cloud CLI"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    -o /etc/apt/keyrings/cloud.google.gpg
  echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    >/etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update -qq
  apt-get install -y -qq google-cloud-cli
fi

META_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
fetch_meta() {
  curl -fsS -H "Metadata-Flavor: Google" "${META_URL}/$1"
}

install -d -m 0755 /opt/dr
install -d -m 0750 -o www-data -g www-data /var/lib/dr-app

# --- Application ------------------------------------------------------------
fetch_meta app-py >/opt/dr/app.py
chmod 0644 /opt/dr/app.py

# --- Backup tooling ---------------------------------------------------------
fetch_meta backup-script >/opt/dr/backup.sh
fetch_meta verify-script >/opt/dr/verify-backup.sh
chmod 0750 /opt/dr/backup.sh /opt/dr/verify-backup.sh

BACKUP_BUCKET="$(fetch_meta backup-bucket)"
BACKUP_CRON="$(fetch_meta backup-cron)"
# Sanity-check the schedule before it becomes a cron file (a malformed
# expression here would silently disable backups — cron rejects the line).
if ! grep -qE '^[^\s]+(\s+[^\s]+){4}$' <<<"${BACKUP_CRON}"; then
  echo "ERROR: invalid backup-cron metadata: '${BACKUP_CRON}'" >&2
  exit 1
fi

cat >/etc/dr-backup.env <<EOF
BACKUP_BUCKET=${BACKUP_BUCKET}
DB_PATH=/var/lib/dr-app/app.db
EOF
chmod 0640 /etc/dr-backup.env

# Backup schedule comes from instance metadata (Terraform var backup_cron) —
# THE RPO dial. Default 02:00 UTC leaves up to ~22h data loss (measured 18h,
# JOURNEY.md Day 6); hourly ('0 * * * *') gets RPO <1h at $0 extra.
# NOTE: startup scripts run once; cadence changes apply on VM recreation.
printf '%s root /opt/dr/backup.sh >> /var/log/dr-backup.log 2>&1\n' "${BACKUP_CRON}" \
  >/etc/cron.d/dr-backup
chmod 0644 /etc/cron.d/dr-backup

# --- Database ---------------------------------------------------------------
# `runuser` rather than `sudo`: the startup script already runs as root,
# and Debian 12's minimal images do not ship `sudo` by default, so
# `sudo -u www-data` would abort provisioning with "command not found"
# under `set -e`. `runuser` is part of util-linux and is always present.
runuser -u www-data -- env DR_DB_PATH=/var/lib/dr-app/app.db \
  python3 /opt/dr/app.py --init-db

# --- gunicorn service -------------------------------------------------------
cat >/etc/systemd/system/dr-app.service <<'EOF'
[Unit]
Description=DR demo app (gunicorn)
After=network.target

[Service]
User=www-data
Group=www-data
Environment=DR_DB_PATH=/var/lib/dr-app/app.db
WorkingDirectory=/opt/dr
ExecStart=/usr/bin/gunicorn --bind 127.0.0.1:8000 --workers 2 app:app
Restart=always
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/dr-app
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dr-app.service

# --- nginx ------------------------------------------------------------------
# Install the site config BEFORE reloading nginx, and wait for the app
# to be answering first.
#
# The base image already runs nginx with its default site, so between
# boot and this point the VM serves nginx's 404 page on port 80. The
# uptime check probes /health every 60s and the alert policy opens an
# incident after 5 minutes of failure — so a slow provisioning run
# (apt-get installing the gcloud CLI can take minutes) would look
# exactly like a dead site and trigger a failover for no reason.
#
# Starting the app first and waiting for it removes that window.
for _ in $(seq 1 30); do
  if curl -fsS -m 2 http://127.0.0.1:8000/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

fetch_meta nginx-conf >/etc/nginx/sites-available/dr-app
ln -sf /etc/nginx/sites-available/dr-app /etc/nginx/sites-enabled/dr-app
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# --- SSH hardening (parity with the VPN project baseline) --------------------
sed -i \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
  /etc/ssh/sshd_config
systemctl reload ssh

install -d "$(dirname "${MARKER}")"
touch "${MARKER}"
echo "dr-primary: provisioning complete"
