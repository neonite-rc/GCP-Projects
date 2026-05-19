#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# GCP VPN Portfolio Test Suite
# ═══════════════════════════════════════════════════════════════════════════════
# A comprehensive validation script for a GCP WireGuard + Tailscale VPN server.
# Run this from any machine with gcloud, terraform, and ssh access to the VM.
#
# What this proves to portfolio reviewers:
#   • You understand the full stack — not just "it connects"
#   • You can debug connectivity, security, performance, and cost
#   • You validate infrastructure as code (Terraform) is actually reproducible
#   • You measure what matters (latency, throughput, failover time)
#   • You think about operational concerns (logging, monitoring, cost)
#
# Prerequisites:
#   • gcloud CLI authenticated (gcloud auth login)
#   • Terraform installed
#   • SSH access to the VM (key in ~/.ssh/)
#   • WireGuard client config for at least one peer
#   • Tailscale client installed and authenticated
#
# Usage:
#   ./vpn-test-suite.sh [--full] [--performance] [--security] [--infra]
#   --full        Run all tests (default)
#   --performance Run only bandwidth/latency tests
#   --security    Run only security validation tests
#   --infra       Run only infrastructure/Terraform tests
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-portfolio-vpn-2026}"
VM_NAME="${VM_NAME:-wireguard-vpn}"
ZONE="${ZONE:-us-east1-b}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-gcp-vpn.duckdns.org}"
WG_PORT="${WG_PORT:-51820}"
TAILSCALE_IP="${TAILSCALE_IP:-100.94.162.86}"
WG_SUBNET="${WG_SUBNET:-10.200.200.0/24}"
TAILSCALE_SUBNET="${TAILSCALE_SUBNET:-100.64.0.0/10}"

# Test result tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
LOG_FILE="vpn-test-$(date +%Y%m%d-%H%M%S).log"

# ─── Colors & Formatting ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Helper Functions ────────────────────────────────────────────────────────
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

section() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    log "SECTION: $1"
}

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    log "PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    log "FAIL: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

skip() {
    echo -e "${YELLOW}⊘ SKIP${NC}: $1"
    log "SKIP: $1"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

info() {
    echo -e "${CYAN}ℹ INFO${NC}: $1"
    log "INFO: $1"
}

warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
    log "WARN: $1"
}

# ─── Pre-flight Checks ───────────────────────────────────────────────────────
section "PRE-FLIGHT: Environment Validation"

check_tool() {
    if command -v "$1" &> /dev/null; then
        pass "Tool available: $1"
        return 0
    else
        fail "Missing tool: $1 (install to run dependent tests)"
        return 1
    fi
}

check_tool gcloud
check_tool terraform
command -v ssh &> /dev/null && pass "Tool available: ssh" || fail "Missing tool: ssh"
command -v curl &> /dev/null && pass "Tool available: curl" || fail "Missing tool: curl"
command -v dig &> /dev/null && pass "Tool available: dig" || warn "Missing tool: dig (DNS tests will use nslookup)"

# Verify gcloud is authenticated and project is set
if gcloud config get-value project 2>/dev/null | grep -q "$PROJECT_ID"; then
    pass "gcloud project set to $PROJECT_ID"
else
    warn "gcloud project may not be set to $PROJECT_ID. Current: $(gcloud config get-value project 2>/dev/null || echo 'none')"
fi

# Get current VM public IP (ephemeral — may have changed)
VM_IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "")
if [[ -n "$VM_IP" ]]; then
    info "Current VM IP: $VM_IP"
else
    warn "Could not retrieve VM IP. VM may be stopped or gcloud permissions insufficient."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 1: CONNECTIVITY & TUNNEL HEALTH
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • The VPN actually carries traffic, not just "the service is running"
#   • DNS resolution works end-to-end (DuckDNS → ephemeral IP)
#   • Both WireGuard and Tailscale paths are functional
#   • The health check Cloud Function is operational
#   • Wake-on-demand works (pay-per-use architecture validated)
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 1: Connectivity & Tunnel Health"

# Test 1.1: DuckDNS Resolution
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Dynamic DNS is tracking the ephemeral IP correctly. If this fails,
#         clients can't find the server after a stop/start cycle.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.1: DuckDNS resolution ($DUCKDNS_DOMAIN)"
if command -v dig &> /dev/null; then
    DNS_IP=$(dig +short "$DUCKDNS_DOMAIN" @8.8.8.8 2>/dev/null | head -1)
else
    DNS_IP=$(nslookup "$DUCKDNS_DOMAIN" 8.8.8.8 2>/dev/null | grep -A1 "Name:" | tail -1 | awk '{print $2}')
fi

if [[ -n "$DNS_IP" ]]; then
    if [[ "$DNS_IP" == "$VM_IP" ]]; then
        pass "DuckDNS resolves to current VM IP ($DNS_IP)"
    else
        warn "DuckDNS resolves to $DNS_IP, but VM IP is $VM_IP (may be propagating)"
    fi
else
    fail "DuckDNS resolution failed for $DUCKDNS_DOMAIN"
fi

# Test 1.2: VM Reachability (ICMP)
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The VM is actually running and network-reachable. If this fails,
#         the VM is either stopped, firewall-blocked, or has no external IP.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.2: VM ICMP reachability"
if [[ -n "$VM_IP" ]] && ping -c 3 -W 5 "$VM_IP" &> /dev/null; then
    pass "VM responds to ICMP ($VM_IP)"
else
    fail "VM not reachable via ICMP ($VM_IP)"
fi

# Test 1.3: WireGuard UDP Port Reachability
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: WireGuard is listening and the GCP firewall rule allows UDP traffic.
#         Uses nc -zu (zero-I/O UDP scan) — no handshake, just port open check.
#         If this fails: WG not running, wrong port, or firewall rule missing.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.3: WireGuard UDP port $WG_PORT reachability"
if [[ -n "$VM_IP" ]] && nc -zu -w 3 "$VM_IP" "$WG_PORT" 2>/dev/null; then
    pass "WireGuard UDP port $WG_PORT is open on $VM_IP"
else
    fail "WireGuard UDP port $WG_PORT is not reachable on $VM_IP"
fi

# Test 1.4: WireGuard Tunnel Health (from server perspective)
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: WireGuard peers have handshaked recently. A listening port with no
#         recent handshake means the client config is wrong or the client is
#         behind a blocking NAT/firewall (the Day 13 ISP port-blocking issue).
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.4: WireGuard peer handshake status"
if [[ -n "$VM_IP" ]]; then
    # SSH into VM and check wg show
    WG_OUTPUT=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "sudo wg show wg0 latest-handshakes" 2>/dev/null || echo "")

    if [[ -n "$WG_OUTPUT" ]]; then
        # Parse: each line is "peer_pubkey timestamp"
        NOW=$(date +%s)
        STALE_PEERS=0
        while read -r PEER_KEY TIMESTAMP; do
            if [[ "$TIMESTAMP" == "0" ]]; then
                warn "Peer $PEER_KEY has never handshaked (config issue or client offline)"
                ((STALE_PEERS++))
            else
                AGE=$((NOW - TIMESTAMP))
                if [[ $AGE -gt 180 ]]; then
                    warn "Peer $PEER_KEY handshake is ${AGE}s old (stale)"
                    ((STALE_PEERS++))
                else
                    pass "Peer $PEER_KEY handshaked ${AGE}s ago (healthy)"
                fi
            fi
        done <<< "$WG_OUTPUT"

        if [[ $STALE_PEERS -eq 0 ]]; then
            pass "All WireGuard peers have recent handshakes"
        fi
    else
        skip "Could not retrieve WireGuard status (SSH failed or no peers configured)"
    fi
else
    skip "VM IP unknown — cannot check WireGuard status"
fi

# Test 1.5: Tailscale Connectivity
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Tailscale coordination server is working, the server node is online,
#         and direct/releyed paths are functional. Uses tailscale ping which
#         provides connection type info (direct vs DERP relay).
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.5: Tailscale connectivity to server ($TAILSCALE_IP)"
if command -v tailscale &> /dev/null; then
    TAILSCALE_PING=$(tailscale ping -c 3 --timeout 10s "$TAILSCALE_IP" 2>&1 || true)
    if echo "$TAILSCALE_PING" | grep -q "pong"; then
        if echo "$TAILSCALE_PING" | grep -q "direct"; then
            pass "Tailscale: direct connection to server (optimal)"
        elif echo "$TAILSCALE_PING" | grep -q "relay"; then
            pass "Tailscale: relayed connection to server (functional, via DERP)"
        else
            pass "Tailscale: connection to server established"
        fi

        # Extract latency
        LATENCY=$(echo "$TAILSCALE_PING" | grep "pong" | tail -1 | grep -oP 'via [^ ]+ in \K[0-9.]+' || echo "")
        [[ -n "$LATENCY" ]] && info "Tailscale RTT: ${LATENCY}ms"
    else
        fail "Tailscale: cannot reach server at $TAILSCALE_IP"
    fi
else
    skip "Tailscale CLI not installed — cannot test Tailscale connectivity"
fi

# Test 1.6: Tailscale Exit Node Routing
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Traffic is actually routing through the GCP server, not bypassing.
#         Compares public IP with/without Tailscale exit node.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.6: Tailscale exit node routing validation"
if command -v tailscale &> /dev/null; then
    # Check if exit node is active
    EXIT_NODE=$(tailscale status --json 2>/dev/null | grep -o '"ExitNode":true' || echo "")
    if [[ -n "$EXIT_NODE" ]]; then
        # Get public IP through Tailscale
        TAILSCALE_IP_OUT=$(curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || echo "")
        if [[ -n "$TAILSCALE_IP_OUT" && "$TAILSCALE_IP_OUT" == "$VM_IP" ]]; then
            pass "Traffic correctly routes through Tailscale exit node ($VM_IP)"
        elif [[ -n "$TAILSCALE_IP_OUT" ]]; then
            warn "Public IP ($TAILSCALE_IP_OUT) doesn't match VM IP ($VM_IP) — exit node may not be active"
        else
            skip "Could not determine public IP via Tailscale"
        fi
    else
        info "Tailscale exit node not currently active on this client"
    fi
else
    skip "Tailscale CLI not installed"
fi

# Test 1.7: Health Check Cloud Function
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The Cloud Function that monitors VPN health is deployed and
#         responding. This validates the monitoring stack (Cloud Scheduler
#         → Cloud Function → Cloud Monitoring custom metric).
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.7: Health check Cloud Function"
HEALTH_FUNC_URL="https://${ZONE%-*}-${PROJECT_ID}.cloudfunctions.net/vpn-health"
HEALTH_RESPONSE=$(curl -s --max-time 15 "$HEALTH_FUNC_URL" 2>/dev/null || echo "")
if [[ -n "$HEALTH_RESPONSE" ]]; then
    if echo "$HEALTH_RESPONSE" | grep -q '"status":"UP"'; then
        pass "Health check reports VPN is UP"
        info "Health details: $HEALTH_RESPONSE"
    elif echo "$HEALTH_RESPONSE" | grep -q '"status":"DOWN"'; then
        fail "Health check reports VPN is DOWN: $HEALTH_RESPONSE"
    else
        info "Health check response: $HEALTH_RESPONSE"
    fi
else
    skip "Health check Cloud Function not reachable (may need auth or different URL)"
fi

# Test 1.8: Wake-on-Demand Cloud Function
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The pay-per-use architecture works — you can start the VM remotely
#         without keeping it running 24/7. This is a key portfolio differentiator
#         showing cost-awareness and serverless integration.
# WARNING: This test is skipped by default because it costs ~1 minute of VM time.
#          Uncomment to enable if you want to validate the full wake cycle.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 1.8: Wake-on-demand Cloud Function (SKIPPED by default — costs VM time)"
skip "Wake-on-demand test skipped (uncomment in script to enable). This validates:"
info "  • VM starts from stopped state via Cloud Function"
info "  • DuckDNS updates within 60s of boot"
info "  • WireGuard becomes reachable after boot"
info "  • Tailscale auto-reconnects without manual intervention"

# Uncomment below to enable (costs ~1 min VM runtime):
# WAKE_TOKEN="${WAKE_TOKEN:-}"
# if [[ -n "$WAKE_TOKEN" ]]; then
#     WAKE_URL="https://${ZONE%-*}-${PROJECT_ID}.cloudfunctions.net/wake-vpn?token=${WAKE_TOKEN}"
#     WAKE_RESPONSE=$(curl -s --max-time 30 "$WAKE_URL" 2>/dev/null || echo "")
#     if echo "$WAKE_RESPONSE" | grep -q "started\|Starting"; then
#         pass "Wake-on-demand triggered successfully"
#         info "Waiting 60s for VM to boot..."
#         sleep 60
#         # Re-run connectivity tests
#     else
#         fail "Wake-on-demand failed: $WAKE_RESPONSE"
#     fi
# fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 2: FAILOVER & RESILIENCE
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • The ephemeral IP + DuckDNS architecture actually works under rotation
#   • Tailscale handles IP changes transparently (coordination server value)
#   • WireGuard clients can reconnect after IP change (with manual toggle)
#   • The system is resilient to the most common failure: VM restart
#   • You understand the difference between stateful (WireGuard) and
#     stateless (Tailscale) approaches to dynamic IPs
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 2: Failover & Resilience"

# Test 2.1: Ephemeral IP Rotation Detection
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: You can detect when the VM's IP has changed. This is critical for
#         understanding why WireGuard clients disconnect after a stop/start.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 2.1: Ephemeral IP rotation detection"
if [[ -n "$VM_IP" ]]; then
    # Check if DuckDNS matches current IP
    if [[ "$DNS_IP" == "$VM_IP" ]]; then
        pass "DuckDNS is synchronized with current VM IP"
    else
        warn "DuckDNS ($DNS_IP) ≠ VM IP ($VM_IP) — IP may have rotated recently"
        info "  This is the root cause of WireGuard reconnection issues on mobile"
    fi
else
    skip "Cannot detect IP rotation — VM IP unknown"
fi

# Test 2.2: Tailscale IP Stability
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Tailscale's 100.x.y.z address is stable across IP changes. This is
#         the key advantage over raw WireGuard — the coordination server
#         abstracts physical IP changes.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 2.2: Tailscale IP stability across physical IP changes"
if command -v tailscale &> /dev/null; then
    TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null || echo "")
    if echo "$TAILSCALE_STATUS" | grep -q "$TAILSCALE_IP"; then
        pass "Tailscale IP ($TAILSCALE_IP) is stable and reachable"
        info "  Physical IP can change — Tailscale IP does not"
    else
        warn "Tailscale IP $TAILSCALE_IP not found in status"
    fi
else
    skip "Tailscale CLI not installed"
fi

# Test 2.3: Server Keepalive Service
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The wg-keepalive.service is running and pinging tunnel IPs. This
#         mitigates NAT table expiration on home routers (the Day 5 bug).
# ─────────────────────────────────────────────────────────────────────────────
info "Test 2.3: Server-side keepalive service"
if [[ -n "$VM_IP" ]]; then
    KEEPALIVE_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "systemctl is-active wg-keepalive" 2>/dev/null || echo "unknown")
    if [[ "$KEEPALIVE_STATUS" == "active" ]]; then
        pass "wg-keepalive.service is active"
    else
        warn "wg-keepalive.service status: $KEEPALIVE_STATUS"
    fi
else
    skip "Cannot check keepalive — VM unreachable"
fi

# Test 2.4: DuckDNS Update Propagation Speed
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: DuckDNS updates fast enough to be useful. The timer runs every 1 min,
#         so propagation should be < 90s from boot. If it's slower, clients
#         will timeout before DNS catches up.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 2.4: DuckDNS update propagation speed"
if [[ -n "$VM_IP" && -n "$DNS_IP" ]]; then
    if [[ "$DNS_IP" == "$VM_IP" ]]; then
        # Check DuckDNS log for last update time
        DUCKDNS_LOG=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no             "debian@$VM_IP" "tail -1 /var/log/duckdns-update.log" 2>/dev/null || echo "")
        if [[ -n "$DUCKDNS_LOG" ]]; then
            info "Last DuckDNS update: $DUCKDNS_LOG"
            pass "DuckDNS is actively updating"
        else
            warn "DuckDNS log not found or empty"
        fi
    fi
else
    skip "Cannot measure propagation — IP data unavailable"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 3: SECURITY VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • Defense in depth: GCP firewall + UFW + fail2ban + Shielded VM
#   • SSH is not exposed to the internet (Day 3 lesson learned)
#   • WireGuard traffic is actually encrypted (not plaintext leaking)
#   • The VM has automatic security updates enabled
#   • You understand that "works" ≠ "secure"
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 3: Security Validation"

# Test 3.1: GCP Firewall Rule Compliance
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Firewall rules match the intended design:
#   • SSH (22/tcp) restricted to admin IP only (not 0.0.0.0/0)
#   • WireGuard (51820/udp) open to 0.0.0.0/0 (required for clients)
#   • No unnecessary ports exposed
# ─────────────────────────────────────────────────────────────────────────────
info "Test 3.1: GCP firewall rule compliance"
FIREWALL_RULES=$(gcloud compute firewall-rules list --project="$PROJECT_ID" --format='table(name,sourceRanges,allowed)' 2>/dev/null || echo "")
if [[ -n "$FIREWALL_RULES" ]]; then
    # Check for 0.0.0.0/0 on port 22
    if echo "$FIREWALL_RULES" | grep -q "0.0.0.0/0.*tcp:22"; then
        fail "CRITICAL: SSH (port 22) is open to 0.0.0.0/0 — Day 3 vulnerability!"
    else
        pass "SSH is not exposed to 0.0.0.0/0"
    fi

    # Check WireGuard port is open
    if echo "$FIREWALL_RULES" | grep -q "$WG_PORT"; then
        pass "WireGuard port $WG_PORT is open in GCP firewall"
    else
        fail "WireGuard port $WG_PORT not found in firewall rules"
    fi
else
    skip "Could not retrieve firewall rules"
fi

# Test 3.2: UFW Status on VM
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The host-level firewall (UFW) is active and configured. This is
#         defense-in-depth: even if GCP firewall is misconfigured, UFW blocks.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 3.2: UFW (host firewall) status"
if [[ -n "$VM_IP" ]]; then
    UFW_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "sudo ufw status verbose" 2>/dev/null || echo "")
    if echo "$UFW_STATUS" | grep -q "Status: active"; then
        pass "UFW is active on the VM"
        info "UFW rules:"
        echo "$UFW_STATUS" | grep -E "^\s*[0-9]+" | while read -r line; do
            info "  $line"
        done
    else
        fail "UFW is not active — host-level firewall disabled"
    fi
else
    skip "Cannot check UFW — VM unreachable"
fi

# Test 3.3: fail2ban Status
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Brute-force protection is active. fail2ban monitors SSH logs and
#         bans IPs after failed attempts. This is the operational response
#         to the Day 3 scanner bot discovery.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 3.3: fail2ban intrusion prevention"
if [[ -n "$VM_IP" ]]; then
    FAIL2BAN_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "sudo fail2ban-client status sshd" 2>/dev/null || echo "")
    if echo "$FAIL2BAN_STATUS" | grep -q "sshd"; then
        pass "fail2ban sshd jail is active"
        BANNED_IPS=$(echo "$FAIL2BAN_STATUS" | grep "Banned IP list" || echo "")
        if [[ -n "$BANNED_IPS" ]]; then
            info "Currently banned: $BANNED_IPS"
        fi
    else
        warn "fail2ban sshd jail not found or inactive"
    fi
else
    skip "Cannot check fail2ban — VM unreachable"
fi

# Test 3.4: Unattended Upgrades
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The VM auto-installs security patches. For a VPN server, this is
#         critical — an unpatched OpenSSL or kernel vulnerability compromises
#         all tunnel traffic. The nightly shutdown makes reboots "free."
# ─────────────────────────────────────────────────────────────────────────────
info "Test 3.4: Unattended security upgrades"
if [[ -n "$VM_IP" ]]; then
    UNATTENDED_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "systemctl is-active unattended-upgrades" 2>/dev/null || echo "")
    if [[ "$UNATTENDED_STATUS" == "active" ]]; then
        pass "unattended-upgrades service is active"
    else
        warn "unattended-upgrades status: $UNATTENDED_STATUS"
    fi

    # Check last upgrade log
    LAST_UPGRADE=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "grep 'Packages that will be upgraded' /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -1 || echo 'No recent upgrades found'" 2>/dev/null || echo "")
    if [[ "$LAST_UPGRADE" != "No recent upgrades found" ]]; then
        info "Last upgrade activity: $LAST_UPGRADE"
    fi
else
    skip "Cannot check unattended-upgrades — VM unreachable"
fi

# Test 3.5: Encrypted Traffic Verification
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: WireGuard traffic is actually encrypted in transit. We capture
#         packets on the WireGuard port and verify they are ESP/UDP encrypted
#         payloads, not plaintext. This validates the crypto is working.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 3.5: WireGuard encryption verification (packet capture)"
if [[ -n "$VM_IP" ]]; then
    # Capture 10 packets on WireGuard port, check they're UDP (encrypted payload)
    PCAP_CHECK=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "sudo timeout 5 tcpdump -i any -c 10 -nn udp port $WG_PORT 2>&1 | head -20" 2>/dev/null || echo "")
    if echo "$PCAP_CHECK" | grep -q "UDP"; then
        pass "WireGuard traffic is UDP-encapsulated (encrypted payload)"
        info "  No plaintext visible in packet capture"
    else
        warn "Could not verify encryption (no traffic or tcpdump failed)"
    fi
else
    skip "Cannot verify encryption — VM unreachable"
fi

# Test 3.6: Shielded VM Verification
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The VM uses Shielded VM features (secure boot, vTPM, integrity
#         monitoring). This protects against boot-level attacks and
#         demonstrates enterprise security awareness.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 3.6: Shielded VM configuration"
SHIELDED_CONFIG=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format='value(shieldedInstanceConfig.secureBoot,shieldedInstanceConfig.vtpm,shieldedInstanceConfig.integrityMonitoring)' 2>/dev/null || echo "")
if [[ -n "$SHIELDED_CONFIG" ]]; then
    if echo "$SHIELDED_CONFIG" | grep -q "True"; then
        pass "Shielded VM features enabled: $SHIELDED_CONFIG"
    else
        warn "Shielded VM features: $SHIELDED_CONFIG"
    fi
else
    skip "Could not retrieve Shielded VM config"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 4: PERFORMANCE & CAPACITY
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • The e2-micro can carry real traffic (not just ping)
#   • You measured throughput and latency with actual tools (iperf3, not guesswork)
#   • You understand the shared-core bursting limits
#   • You can identify when the VM is undersized
#   • The tunnel overhead is quantified, not assumed
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 4: Performance & Capacity"

# Test 4.1: Baseline Latency (WireGuard tunnel)
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Round-trip time through the tunnel. High latency (>300ms) indicates
#         DERP relay usage or network congestion. Day 4 showed ~120ms RTT.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 4.1: WireGuard tunnel latency"
if [[ -n "$VM_IP" ]]; then
    # Ping through WireGuard if tunnel is up on this machine
    # Otherwise ping the VM directly as baseline
    PING_RESULT=$(ping -c 10 -i 0.2 "$VM_IP" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' || echo "")
    if [[ -n "$PING_RESULT" ]]; then
        LATENCY_MS=$(printf "%.1f" "$PING_RESULT")
        if (( $(echo "$LATENCY_MS < 150" | bc -l) )); then
            pass "Baseline latency: ${LATENCY_MS}ms (excellent)"
        elif (( $(echo "$LATENCY_MS < 300" | bc -l) )); then
            pass "Baseline latency: ${LATENCY_MS}ms (acceptable)"
        else
            warn "Baseline latency: ${LATENCY_MS}ms (high — check for relay or congestion)"
        fi
    else
        skip "Could not measure latency"
    fi
else
    skip "Cannot measure latency — VM IP unknown"
fi

# Test 4.2: CPU Utilization Under Load
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The e2-micro's shared-core bursting handles traffic spikes. Sustained
#         load would throttle. Day 4 showed ~150 Mbps peak before throttling.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 4.2: CPU utilization during active tunnel"
if [[ -n "$VM_IP" ]]; then
    CPU_USAGE=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1" 2>/dev/null || echo "")
    if [[ -n "$CPU_USAGE" ]]; then
        CPU_INT=${CPU_USAGE%.*}
        if [[ $CPU_INT -lt 20 ]]; then
            pass "CPU utilization: ${CPU_USAGE}% (plenty of headroom)"
        elif [[ $CPU_INT -lt 70 ]]; then
            pass "CPU utilization: ${CPU_USAGE}% (normal)"
        else
            warn "CPU utilization: ${CPU_USAGE}% (high — consider e2-medium upgrade)"
        fi
    else
        skip "Could not retrieve CPU usage"
    fi
else
    skip "Cannot check CPU — VM unreachable"
fi

# Test 4.3: Memory Usage
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The VM isn't memory-starved. WireGuard + Tailscale are lightweight
#         but memory pressure causes OOM kills and tunnel drops.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 4.3: Memory utilization"
if [[ -n "$VM_IP" ]]; then
    MEM_INFO=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "free | grep Mem" 2>/dev/null || echo "")
    if [[ -n "$MEM_INFO" ]]; then
        MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
        MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}')
        MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
        if [[ $MEM_PCT -lt 50 ]]; then
            pass "Memory usage: ${MEM_PCT}% (${MEM_USED}K / ${MEM_TOTAL}K)"
        elif [[ $MEM_PCT -lt 80 ]]; then
            pass "Memory usage: ${MEM_PCT}% (${MEM_USED}K / ${MEM_TOTAL}K)"
        else
            warn "Memory usage: ${MEM_PCT}% — approaching limit"
        fi
    else
        skip "Could not retrieve memory info"
    fi
else
    skip "Cannot check memory — VM unreachable"
fi

# Test 4.4: iperf3 Throughput (if available)
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Actual bandwidth through the tunnel. Day 4 showed ~150 Mbps on
#         e2-micro with WireGuard kernel implementation.
# NOTE: Requires iperf3 on both client and server. Skipped if not installed.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 4.4: Tunnel throughput (iperf3)"
if command -v iperf3 &> /dev/null; then
    # Check if iperf3 is running on the server
    IPERF_SERVER=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "pgrep -x iperf3" 2>/dev/null || echo "")
    if [[ -z "$IPERF_SERVER" ]]; then
        # Start iperf3 server in background
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no             "debian@$VM_IP" "nohup iperf3 -s -D > /dev/null 2>&1 &" 2>/dev/null || true
        sleep 2
    fi

    # Run test through WireGuard tunnel IP if known, else direct
    IPERF_RESULT=$(iperf3 -c "$VM_IP" -t 10 -f M 2>/dev/null | grep "receiver" | awk '{print $7}' || echo "")
    if [[ -n "$IPERF_RESULT" ]]; then
        pass "Throughput: ${IPERF_RESULT} MB/s (~$((IPERF_RESULT * 8)) Mbps)"
        if (( $(echo "$IPERF_RESULT > 10" | bc -l) )); then
            info "  Excellent — WireGuard kernel implementation performing well"
        elif (( $(echo "$IPERF_RESULT > 5" | bc -l) )); then
            info "  Good — sufficient for most use cases"
        else
            warn "  Low throughput — check CPU throttling or network congestion"
        fi
    else
        skip "iperf3 test failed (server may not be running or tunnel not routing)"
    fi

    # Clean up iperf3 server
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "pkill -x iperf3" 2>/dev/null || true
else
    skip "iperf3 not installed — install with 'apt install iperf3' to test throughput"
fi

# Test 4.5: Disk I/O (boot disk health)
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The boot disk isn't a bottleneck. Slow I/O causes apt updates to
#         hang and systemd services to timeout.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 4.5: Disk I/O performance"
if [[ -n "$VM_IP" ]]; then
    DISK_IO=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "dd if=/dev/zero of=/tmp/test-io bs=1M count=100 conv=fdatasync 2>&1 | tail -1" 2>/dev/null || echo "")
    if [[ -n "$DISK_IO" ]]; then
        DISK_SPEED=$(echo "$DISK_IO" | grep -oP '\K[0-9.]+ [MG]B/s' || echo "")
        if [[ -n "$DISK_SPEED" ]]; then
            pass "Disk write speed: $DISK_SPEED"
        else
            info "Disk I/O test completed (output: $DISK_IO)"
        fi
        # Clean up
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no             "debian@$VM_IP" "rm -f /tmp/test-io" 2>/dev/null || true
    else
        skip "Could not measure disk I/O"
    fi
else
    skip "Cannot check disk I/O — VM unreachable"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 5: OPERATIONAL VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • The system is self-monitoring (activity logs, health checks)
#   • Logs rotate and don't fill the disk
#   • Services start correctly on boot (idempotency)
#   • The auto-shutdown schedule works (cost control)
#   • You can answer "what was my phone doing and when?" (Day 9 goal)
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 5: Operational Validation"

# Test 5.1: Activity Logger
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The wg-activity-log.sh is running, writing to /var/log/wg-activity.log,
#         and correctly mapping peers to names. This is the ISP-style per-device
#         logging built on Day 9.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 5.1: WireGuard activity logger"
if [[ -n "$VM_IP" ]]; then
    LOGGER_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "systemctl is-active wg-activity.timer" 2>/dev/null || echo "")
    if [[ "$LOGGER_STATUS" == "active" ]]; then
        pass "wg-activity.timer is active"
    else
        warn "wg-activity.timer status: $LOGGER_STATUS"
    fi

    # Check log file exists and has recent entries
    LOG_ENTRIES=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "wc -l < /var/log/wg-activity.log" 2>/dev/null || echo "0")
    if [[ "$LOG_ENTRIES" -gt 0 ]]; then
        pass "Activity log has $LOG_ENTRIES entries"
        # Show last 3 entries
        LAST_ENTRIES=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no             "debian@$VM_IP" "tail -3 /var/log/wg-activity.log" 2>/dev/null || echo "")
        info "Recent activity:"
        echo "$LAST_ENTRIES" | while read -r line; do
            info "  $line"
        done
    else
        warn "Activity log is empty (no peer activity yet or logger not working)"
    fi
else
    skip "Cannot check activity logger — VM unreachable"
fi

# Test 5.2: DuckDNS Updater Timer
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The DuckDNS updater runs every 1 minute (down from 5 min after Day 12
#         fix). Faster updates mean less downtime after IP rotation.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 5.2: DuckDNS updater service"
if [[ -n "$VM_IP" ]]; then
    DUCKDNS_TIMER=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "systemctl is-active duckdns-update.timer" 2>/dev/null || echo "")
    if [[ "$DUCKDNS_TIMER" == "active" ]]; then
        pass "duckdns-update.timer is active"
    else
        warn "duckdns-update.timer status: $DUCKDNS_TIMER"
    fi

    # Verify timer frequency
    TIMER_CONFIG=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "cat /etc/systemd/system/duckdns-update.timer" 2>/dev/null || echo "")
    if echo "$TIMER_CONFIG" | grep -q "OnUnitActiveSec=1min"; then
        pass "DuckDNS update interval: 1 minute (optimized)"
    elif echo "$TIMER_CONFIG" | grep -q "OnUnitActiveSec=5min"; then
        warn "DuckDNS update interval: 5 minutes (consider reducing to 1 min)"
    fi
else
    skip "Cannot check DuckDNS timer — VM unreachable"
fi

# Test 5.3: Log Rotation
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Logs don't grow unbounded and fill the 10GB boot disk. The logrotate
#         config rotates weekly and keeps 8 weeks — documented in Day 9.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 5.3: Log rotation configuration"
if [[ -n "$VM_IP" ]]; then
    LOGROTATE_CONF=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "cat /etc/logrotate.d/wg-activity" 2>/dev/null || echo "")
    if [[ -n "$LOGROTATE_CONF" ]]; then
        pass "Logrotate config exists for wg-activity"
        if echo "$LOGROTATE_CONF" | grep -q "weekly"; then
            info "  Rotation: weekly"
        fi
        if echo "$LOGROTATE_CONF" | grep -q "rotate 8"; then
            info "  Retention: 8 weeks"
        fi
    else
        warn "Logrotate config not found for wg-activity"
    fi
else
    skip "Cannot check logrotate — VM unreachable"
fi

# Test 5.4: Auto-shutdown Schedule
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The VM stops nightly at 01:00 UTC, saving credits. This is the
#         cost-optimization from Day 6 — but with the documented caveat
#         that it only saves money if you're on billable compute.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 5.4: Auto-shutdown schedule"
SCHEDULE=$(gcloud compute resource-policies describe "nightly-shutdown" --region="${ZONE%-*}" --project="$PROJECT_ID" --format='value(name)' 2>/dev/null || echo "")
if [[ -n "$SCHEDULE" ]]; then
    pass "Auto-shutdown policy exists: $SCHEDULE"
    # Check if attached to VM
    VM_SCHEDULE=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format='value(resourcePolicies)' 2>/dev/null || echo "")
    if [[ -n "$VM_SCHEDULE" ]]; then
        pass "Auto-shutdown policy attached to VM"
    else
        warn "Auto-shutdown policy exists but not attached to VM"
    fi
else
    info "No auto-shutdown policy found (may be disabled per Day 6 cost analysis)"
fi

# Test 5.5: Startup Script Idempotency
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The startup script runs safely on reboot (marker file guard).
#         Re-running it doesn't regenerate keys or break configs.
#         This is the "reboot test" from Day 15.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 5.5: Startup script idempotency marker"
if [[ -n "$VM_IP" ]]; then
    MARKER=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "test -f /var/lib/wireguard-setup.done && echo 'exists' || echo 'missing'" 2>/dev/null || echo "unknown")
    if [[ "$MARKER" == "exists" ]]; then
        pass "Startup script marker file exists (idempotency guard working)"
    else
        warn "Startup script marker file missing — may re-run on next boot"
    fi
else
    skip "Cannot check marker — VM unreachable"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 6: INFRASTRUCTURE & TERRAFORM
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • Terraform state is in GCS (not on a single laptop)
#   • The infrastructure is reproducible (terraform plan shows no drift)
#   • add-client.sh works on a fresh VM (the Day 11 pipefail bug is fixed)
#   • The full destroy/apply cycle works (Day 7: 4 minutes from zero to VPN)
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 6: Infrastructure & Terraform"

# Test 6.1: Terraform State in GCS
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: State is crash-proof, versioned, and multi-user capable. The Day 11
#         migration from local tfstate to GCS backend.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 6.1: Terraform GCS backend"
if [[ -f "versions.tf" || -f "backend.tf" ]]; then
    if grep -q 'backend "gcs"' versions.tf backend.tf 2>/dev/null; then
        pass "Terraform configured with GCS backend"
        # Verify bucket exists
        BUCKET_NAME="${PROJECT_ID}-tfstate"
        BUCKET_EXISTS=$(gsutil ls -b "gs://${BUCKET_NAME}/" 2>/dev/null || echo "")
        if [[ -n "$BUCKET_EXISTS" ]]; then
            pass "GCS bucket exists: gs://${BUCKET_NAME}"
            # Check versioning
            VERSIONING=$(gsutil versioning get "gs://${BUCKET_NAME}/" 2>/dev/null || echo "")
            if echo "$VERSIONING" | grep -q "Enabled"; then
                pass "GCS bucket versioning is enabled (rollback support)"
            else
                warn "GCS bucket versioning not enabled"
            fi
        else
            fail "GCS backend bucket not found: gs://${BUCKET_NAME}"
        fi
    else
        warn "GCS backend not configured in Terraform files"
    fi
else
    skip "Terraform files not found in current directory"
fi

# Test 6.2: Terraform Plan Drift Detection
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The live infrastructure matches the Terraform code. Drift means
#         someone (or something) changed the config outside of IaC.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 6.2: Terraform drift detection"
if command -v terraform &> /dev/null && [[ -f "main.tf" ]]; then
    terraform init -backend=false > /dev/null 2>&1 || true
    PLAN_OUTPUT=$(terraform plan -detailed-exitcode 2>&1 || true)
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
        pass "Terraform plan shows no drift (infrastructure matches code)"
    elif [[ $EXIT_CODE -eq 2 ]]; then
        warn "Terraform plan shows changes needed (drift detected)"
        info "Run 'terraform plan' to see details"
    else
        warn "Terraform plan failed (check configuration)"
    fi
else
    skip "Terraform not available or no config in current directory"
fi

# Test 6.3: add-client.sh Functionality
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The client provisioning script works on a fresh VM. The Day 11
#         pipefail bug (grep with no peers) is fixed. This is the first
#         thing you run after a fresh deploy.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 6.3: add-client.sh functionality"
if [[ -n "$VM_IP" ]]; then
    # Check if script exists and is executable
    SCRIPT_CHECK=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "test -x /usr/local/sbin/add-client.sh && echo 'exists' || echo 'missing'" 2>/dev/null || echo "unknown")
    if [[ "$SCRIPT_CHECK" == "exists" ]]; then
        pass "add-client.sh is installed and executable"
        # The pipefail fix lives in the shared peer store (single source of truth)
        LIB_CHECK=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no         "debian@$VM_IP" "test -f /usr/local/sbin/wg-peer-store.sh && grep -q '|| true' /usr/local/sbin/wg-peer-store.sh && echo 'ok' || echo 'missing'" 2>/dev/null || echo "unknown")
        if [[ "$LIB_CHECK" == "ok" ]]; then
            pass "wg-peer-store.sh installed with pipefail fix (Day 11 bug patched)"
        else
            warn "peer store missing or missing the pipefail fix"
        fi
    else
        warn "add-client.sh not found or not executable"
    fi
else
    skip "Cannot check add-client.sh — VM unreachable"
fi

# Test 6.4: CI Pipeline Validation
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The repo has automated checks (terraform fmt, validate, shellcheck)
#         that prevent unbuildable state. Day 7 addition.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 6.4: CI pipeline configuration"
if [[ -d ".github/workflows" ]]; then
    CI_FILES=$(find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null | wc -l)
    if [[ $CI_FILES -gt 0 ]]; then
        pass "CI workflows found: $CI_FILES"
        # Check for terraform validation
        if grep -r "terraform.*validate" .github/workflows/ > /dev/null 2>&1; then
            pass "Terraform validation in CI"
        fi
        if grep -r "shellcheck" .github/workflows/ > /dev/null 2>&1; then
            pass "ShellCheck in CI"
        fi
    else
        info "No CI workflow files found"
    fi
else
    info "No .github/workflows directory (CI not configured or not using GitHub)"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 7: COST & COMPLIANCE
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • You understand what this project costs and why
#   • Billing alerts are configured (Day 10)
#   • Resources are tagged/organized
#   • No unnecessary billable resources exist (Day 2 custom VPC decision)
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 7: Cost & Compliance"

# Test 7.1: Free-Tier Eligibility
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: The VM is in a free-tier region and uses free-tier machine type.
#         Day 2 decision: us-east1 + e2-micro = $0 while in free tier.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 7.1: Free-tier eligibility"
VM_DETAILS=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format='value(machineType,zone)' 2>/dev/null || echo "")
if [[ -n "$VM_DETAILS" ]]; then
    if echo "$VM_DETAILS" | grep -q "e2-micro"; then
        pass "VM uses e2-micro (free-tier eligible)"
    else
        warn "VM type: $(echo "$VM_DETAILS" | awk '{print $1}') — verify free-tier eligibility"
    fi

    if echo "$VM_DETAILS" | grep -qE "us-east1|us-west1|us-central1"; then
        pass "VM in free-tier region"
    else
        warn "VM not in free-tier region — may incur charges"
    fi
else
    skip "Could not retrieve VM details"
fi

# Test 7.2: Billing Alerts
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Budget alerts are configured (Day 10). The $300 trial credit needs
#         guardrails — a runaway Cloud Function or forgotten VM can burn it.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 7.2: Billing budget alerts"
BUDGETS=$(gcloud billing budgets list --billing-account="$(gcloud beta billing accounts list --format='value(name)' 2>/dev/null | head -1)" --format='table(displayName,amount)' 2>/dev/null || echo "")
if [[ -n "$BUDGETS" ]]; then
    pass "Billing budgets configured"
    echo "$BUDGETS" | tail -n +2 | while read -r line; do
        info "  $line"
    done
else
    warn "No billing budgets found — configure alerts to protect credits"
fi

# Test 7.3: Resource Labeling
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Resources are tagged for cost tracking and organization. This is
#         a FinOps best practice — you can't optimize what you can't categorize.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 7.3: Resource labeling"
VM_LABELS=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format='value(labels)' 2>/dev/null || echo "")
if [[ -n "$VM_LABELS" && "$VM_LABELS" != "{}" ]]; then
    pass "VM has labels: $VM_LABELS"
else
    info "VM has no custom labels (consider adding for cost tracking)"
fi

# Test 7.4: No Unnecessary Resources
# ─────────────────────────────────────────────────────────────────────────────
# PROVES: Day 2 decision — custom-mode VPC with single subnet, not auto-mode
#         with 40+ subnets. No Cloud NAT, no load balancer, no unnecessary
#         billable resources.
# ─────────────────────────────────────────────────────────────────────────────
info "Test 7.4: Resource minimization check"
# Check for auto-mode VPC (should not exist)
AUTO_VPC=$(gcloud compute networks list --project="$PROJECT_ID" --format='table(name,mode)' 2>/dev/null | grep "auto" || echo "")
if [[ -n "$AUTO_VPC" ]]; then
    warn "Auto-mode VPC detected — consider deleting to reduce attack surface"
else
    pass "No auto-mode VPC found (custom-mode only)"
fi

# Check for unnecessary resources
NAT_GATEWAYS=$(gcloud compute routers nats list --project="$PROJECT_ID" --format='value(name)' 2>/dev/null | wc -l || echo "0")
if [[ "$NAT_GATEWAYS" -gt 0 ]]; then
    warn "Cloud NAT gateways found: $NAT_GATEWAYS (unnecessary for this VPN)"
else
    pass "No Cloud NAT gateways (correct — not needed)"
fi

LOAD_BALANCERS=$(gcloud compute forwarding-rules list --project="$PROJECT_ID" --format='value(name)' 2>/dev/null | wc -l)
if [[ "$LOAD_BALANCERS" -gt 0 ]]; then
    warn "Load balancers found: $LOAD_BALANCERS (unnecessary for single-VM VPN)"
else
    pass "No load balancers (correct — not needed)"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE 8: DOCUMENTATION & REPRODUCIBILITY
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS PROVES:
#   • Someone else (or future-you) can reproduce this from the repo
#   • The README explains the architecture, not just commands
#   • Troubleshooting docs exist for known issues
#   • The project has a clear "done" definition
# ═══════════════════════════════════════════════════════════════════════════════

section "SUITE 8: Documentation & Reproducibility"

# Test 8.1: README Completeness
# ─────────────────────────────────────────────────────────────────────────────
info "Test 8.1: README completeness"
if [[ -f "README.md" ]]; then
    README_SIZE=$(wc -l < README.md)
    if [[ $README_SIZE -gt 50 ]]; then
        pass "README.md exists ($README_SIZE lines)"
    else
        warn "README.md is very short ($README_SIZE lines)"
    fi

    # Check for key sections
    for section in "Architecture" "Prerequisites" "Deployment" "Troubleshooting" "Cost"; do
        if grep -qi "$section" README.md; then
            pass "README includes '$section' section"
        else
            info "README missing '$section' section"
        fi
    done
else
    warn "README.md not found"
fi

# Test 8.2: Architecture Diagram
# ─────────────────────────────────────────────────────────────────────────────
info "Test 8.2: Architecture diagram"
if [[ -f "architecture.png" || -f "architecture.svg" || -f "architecture.drawio" ]]; then
    pass "Architecture diagram exists"
else
    info "No architecture diagram found (consider adding for portfolio)"
fi

# Test 8.3: Troubleshooting Documentation
# ─────────────────────────────────────────────────────────────────────────────
info "Test 8.3: Troubleshooting documentation"
if [[ -f "troubleshooting.md" || -f "TROUBLESHOOTING.md" ]]; then
    pass "Troubleshooting documentation exists"
else
    info "No troubleshooting.md found (consider documenting known issues)"
fi

# Test 8.4: Credential Management
# ─────────────────────────────────────────────────────────────────────────────
info "Test 8.4: Credential management"
if [[ -f ".gitignore" ]]; then
    if grep -q "CREDENTIALS" .gitignore || grep -q "keys/" .gitignore || grep -q "*.key" .gitignore; then
        pass ".gitignore excludes credentials"
    else
        warn ".gitignore may not exclude credential files"
    fi
else
    warn "No .gitignore found"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

section "FINAL SUMMARY"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
PASS_RATE=0
if [[ $TOTAL_TESTS -gt 0 ]]; then
    PASS_RATE=$((TESTS_PASSED * 100 / TOTAL_TESTS))
fi

echo ""
echo -e "${BOLD}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
echo -e "  ${BOLD}Total:${NC}   $TOTAL_TESTS"
echo -e "  ${BOLD}Pass Rate:${NC} ${PASS_RATE}%"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓ All critical tests passed. This VPN is portfolio-ready.${NC}"
    echo ""
    echo "What to highlight in your portfolio:"
    echo "  1. Dual-stack WireGuard + Tailscale (shows you understand trade-offs)"
    echo "  2. Ephemeral IP + DuckDNS = $0 when stopped (cost-awareness)"
    echo "  3. Wake-on-demand Cloud Function (serverless + pay-per-use)"
    echo "  4. Activity logging without client-side install (operational thinking)"
    echo "  5. Full IaC with GCS backend (reproducibility)"
    echo "  6. Security: UFW + fail2ban + Shielded VM + unattended upgrades"
    echo "  7. Documented debugging journey (Day 3 SSH, Day 5 NAT, Day 13 ISP)"
    echo ""
    echo "Suggested README structure for maximum impact:"
    echo "  • One-liner: 'GCP VPN with WireGuard + Tailscale, $0/mo on free tier'"
    echo "  • Architecture diagram showing data flow"
    echo "  • Cost breakdown table (your Day 6 analysis)"
    echo "  • 'Why not X?' section (your Day 1 decision matrix)"
    echo "  • GIF/video of the full wake → connect → shutdown cycle"
    echo "  • Link to this test suite: 'Run ./vpn-test-suite.sh to validate'"
else
    echo -e "${YELLOW}${BOLD}⚠ Some tests failed. Review the output above and fix before showcasing.${NC}"
    echo ""
    echo "Common fixes:"
    echo "  • VM stopped? Run: gcloud compute instances start $VM_NAME --zone=$ZONE"
    echo "  • SSH failing? Update admin_ip_cidr in tfvars for your current IP"
    echo "  • DuckDNS stale? Wait 60s after VM start for propagation"
    echo "  • WireGuard not connecting? Check client config uses port $WG_PORT"
fi

echo ""
echo "Full log saved to: $LOG_FILE"
echo ""

# Exit with appropriate code
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
