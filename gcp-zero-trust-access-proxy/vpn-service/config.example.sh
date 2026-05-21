#!/usr/bin/env bash
# ~/.config/vpn-service/config.sh
# Copy this file there and fill in your values.

# Path to your Terraform directory (the one with main.tf)
VPN_TERRAFORM_DIR="$HOME/Projects/gcp-vpn-server/vpn-service/terraform"

# GCP project ID (run: gcloud config get-value project)
VPN_PROJECT="portfolio-vpn-2026"

# Tailscale reusable auth key
# Generate at: https://login.tailscale.com/admin/settings/keys
# Tag: tag:vpn (or whatever matches your ACL)
VPN_TS_AUTHKEY=""

# Default region when 'vpn up' has no argument (empty = auto-pick fastest)
VPN_DEFAULT_REGION=""

# Seconds to wait for Tailscale node after provisioning
VPN_CONNECT_TIMEOUT=120

# Machine type (e2-micro is cheapest, e2-medium for more throughput)
VPN_MACHINE_TYPE="e2-micro"

# Optional: hardcode endpoints for latency probing
# Format: "region=ip,region=ip,..."
# VPN_ENDPOINTS="us-east1=34.x.x.x,asia-south1=35.x.x.x"
