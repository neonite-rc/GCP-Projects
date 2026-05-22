#!/usr/bin/env bash
# install-dashboard.sh — install VPN dashboard on the server
# Called by startup.sh after Tailscale is up
set -euo pipefail

DASHBOARD_DIR="/opt/vpn-service/web"
SERVICE_FILE="/etc/systemd/system/vpn-dashboard.service"

echo "[dashboard] Installing..."

# Create directory
mkdir -p "$DASHBOARD_DIR/templates"

# Copy files (assumes they're already on the VM via metadata or startup)
# In production, these would be baked into a custom image or fetched from GCS

# Install systemd service
cat > "$SERVICE_FILE" <<'SERVICE'
[Unit]
Description=VPN Dashboard Server
After=network.target tailscaled.service
Wants=tailscaled.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vpn-service/web
ExecStart=/usr/bin/python3 /opt/vpn-service/web/server.py --port 8080
Restart=always
RestartSec=5

Environment=VPN_TERRAFORM_DIR=/opt/vpn-service/terraform
Environment=VPN_TS_AUTHKEY=
Environment=VPN_PROJECT=

[Install]
WantedBy=multi-user.target
SERVICE

# Reload and start
systemctl daemon-reload
systemctl enable vpn-dashboard
systemctl start vpn-dashboard

echo "[dashboard] Installed and started on port 8080"
echo "[dashboard] Access via Tailscale: http://$(tailscale ip -4):8080"
