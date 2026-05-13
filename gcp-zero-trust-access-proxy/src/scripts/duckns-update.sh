#!/bin/bash
# DuckDNS dynamic DNS updater.
# Queries the VM's public IP and reports it to DuckDNS.
# Runs via systemd timer every 5 minutes.
# Usage: DUCKDNS_TOKEN=<token> DUCKDNS_DOMAIN=<domain> /usr/local/sbin/duckns-update.sh
set -euo pipefail

: "${DUCKDNS_TOKEN:?Set DUCKDNS_TOKEN in /etc/duckdns.env}"
: "${DUCKDNS_DOMAIN:?Set DUCKDNS_DOMAIN in /etc/duckdns.env}"

CURRENT_IP=$(curl -sf https://api.ipify.org || curl -sf https://ifconfig.me || \
  { echo "Failed to detect public IP"; exit 1; })

RESPONSE=$(curl -sf "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${CURRENT_IP}&verbose=true" || \
  { echo "Failed to contact DuckDNS API"; exit 1; })

logger -t duckns-update "IP=${CURRENT_IP} response=${RESPONSE}"
echo "$(date '+%Y-%m-%d %H:%M:%S %Z')  IP=${CURRENT_IP}  response=${RESPONSE}" >> /var/log/duckns-update.log
