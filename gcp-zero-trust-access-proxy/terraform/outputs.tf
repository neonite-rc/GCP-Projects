output "vpn_server_public_ip" {
  description = "Public IP of the primary WireGuard server"
  value       = module.vpn_server.public_ip
}

output "vpn_server_internal_ip" {
  description = "Internal IP of the primary VPN server inside the VPC"
  value       = module.vpn_server.internal_ip
}

output "network_name" {
  description = "Name of the custom VPC"
  value       = module.network.network_name
}

output "ssh_command" {
  description = "Command to SSH into the primary VPN server"
  value       = "ssh ${var.ssh_user}@${module.vpn_server.public_ip}"
}

output "wireguard_endpoint" {
  description = "WireGuard endpoint for client configs (primary)"
  value       = "${module.vpn_server.public_ip}:${var.wireguard_port}"
}

output "wake_vpn_url" {
  description = "Cloud Function URL to wake the primary VPN (append ?token=<wake_token>)"
  value       = module.wake_vpn.url
}

output "vpn_health_url" {
  description = "Cloud Function URL for VPN health check"
  value       = module.vpn_health.url
}

# --- Multi-region outputs ---

output "all_regions" {
  description = "Map of region_key => {public_ip, internal_ip, instance_name, ssh_command, wireguard_endpoint}"
  value = merge(
    {
      (var.primary_region.region) = {
        public_ip          = module.vpn_server.public_ip
        internal_ip        = module.vpn_server.internal_ip
        instance_name      = var.primary_region.instance_name
        ssh_command        = "ssh ${var.ssh_user}@${module.vpn_server.public_ip}"
        wireguard_endpoint = "${module.vpn_server.public_ip}:${var.wireguard_port}"
      }
    },
    { for k, m in module.vpn_server_region : k => {
      public_ip          = m.public_ip
      internal_ip        = m.internal_ip
      instance_name      = var.additional_regions[k].instance_name
      ssh_command        = "ssh ${var.ssh_user}@${m.public_ip}"
      wireguard_endpoint = "${m.public_ip}:${var.wireguard_port}"
    } }
  )
}

output "active_region_count" {
  description = "Number of active VPN server regions"
  value       = 1 + length(local.active_regions)
}

output "dns_name_servers" {
  description = "Cloud DNS name servers (empty if DNS module not enabled)"
  value       = var.dns_zone_name != "" ? module.dns[0].name_servers : []
}
