# Scaling

"What if this needed to support 1000 users?"

## Current limits (measured)

- e2-micro sustains ~150 Mbps WireGuard throughput (tested with 3 clients,
  iperf3). Shared-core CPU is the bottleneck, not the network.
- 10 regions across 4 continents, each a single VM = single point of failure
  per region (but 10 regions = high aggregate availability).

## Global VPN — 10 regions (built)

10 VPN servers across 4 continents, all running simultaneously. Cloud DNS
provides weighted routing so clients hit the closest region.

### Active regions

| # | Region | Location | Cost/mo |
|---|--------|----------|---------|
| 1 | us-east1 | South Carolina, USA | **$0** (free tier) |
| 2 | us-west1 | Oregon, USA | **$0** (free tier) |
| 3 | asia-south1 | Mumbai, India | ~$4.92 |
| 4 | asia-east1 | Taiwan | ~$4.92 |
| 5 | asia-southeast1 | Singapore | ~$5.74 |
| 6 | europe-west1 | Belgium | ~$5.56 |
| 7 | europe-west4 | Netherlands | ~$5.56 |
| 8 | europe-west2 | London, UK | ~$6.38 |
| 9 | asia-northeast1 | Tokyo, Japan | ~$6.38 |
| 10 | southamerica-east1 | São Paulo, Brazil | ~$7.02 |

### How to enable/disable regions

```hcl
# In terraform.tfvars — all 9 additional regions are enabled by default.
# Disable any region by overriding:
additional_regions = {
  "asia-south1" = { ... enabled = false }  # skip Mumbai
  # all others remain enabled
}
```

### Adding a new region

1. Add an entry to `var.additional_regions` in `terraform/variables.tf`
2. Pick the next available subnet CIDR (10.0.x.0/28) and tunnel CIDR (10.200.x.0/24)
3. `terraform apply` — subnet, firewall rule, and VM created automatically
4. Health check picks up the new region on next scheduler run (no code change)

### Client management across regions

```bash
# Add client to local server only:
sudo add-client.sh my-phone

# Add client to all 10 servers:
sudo add-client.sh --region all my-laptop

# Add client to a specific region:
sudo add-client.sh --region asia-south1 my-tablet
```

### Cost impact

| Component | Monthly Cost |
|-----------|-------------|
| 2× e2-micro (US free tier) | **$0** |
| 8× e2-micro (international) | ~$47.48 |
| 10× boot disk 10 GB | $4.00 |
| Cloud DNS zone | $0.20 |
| **Total** | **~$51.68/mo** |

### Health monitoring

The `vpn-health` Cloud Function probes both regions and writes separate
metrics (`vpn/health` for primary, `vpn/health` for secondary) to Cloud
Monitoring. The Cloud Scheduler triggers every 5 minutes.

### Trade-offs

- **Pros:** Geo-routing (lower latency), failover (one region dies, DNS
  routes to the other), $0 extra compute.
- **Cons:** Client configs are per-server (WireGuard has no built-in
  roaming). Tailscale handles this automatically — its coordination
  server tracks IP changes across both VMs. WireGuard clients need
  separate configs for each server endpoint.
- **DNS TTL:** Set to 60s for fast failover. Lower TTL = faster failover
  but more DNS queries. 60s is the sweet spot for a VPN.

## Scaling path

### 10 users — vertical
- e2-micro → e2-medium (~$25/mo). WireGuard is multi-threaded on Linux 5.6+;
  more cores = near-linear throughput gains.
- No architecture change; just `machine_type` in tfvars.

### 100 users — availability
- Managed Instance Group (size 2+) behind an **external passthrough
  Network Load Balancer** (UDP supported).
- Challenge: WireGuard is stateful per peer → need session affinity
  (`CLIENT_IP`) or shared peer config across instances (config in GCS,
  synced on boot).
- Move client key management to a small provisioning API + Secret Manager.

### 1000 users — managed / enterprise
- Replace self-managed WireGuard with:
  - **Cloud VPN** (managed IPsec, $0.05/hr/tunnel, SLA) for site-to-site, or
  - **Identity-Aware Proxy (IAP)** for zero-trust user access — no VPN at
    all; per-request auth with Google identity + context (BeyondCorp).
- Multi-region MIGs + DNS geo-routing for latency.

### Operations at scale
- Terraform module with `client_count` variable and per-client key
  provisioning via Secret Manager.
- Cloud Monitoring: bandwidth per peer, handshake age alerts.
- Config management (Ansible) instead of a startup script.

## When to stop self-hosting

Self-hosted WireGuard wins on cost/control up to roughly a team-sized
deployment. Beyond that, key distribution, revocation, and HA engineering
exceed the cost of IAP/Cloud VPN — buy, don't build.
