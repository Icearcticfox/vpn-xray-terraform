output "droplet_ip" {
  description = "Public IPv4 address of the Xray droplet"
  value       = digitalocean_droplet.xray.ipv4_address
}

output "droplet_ipv6" {
  description = "Public IPv6 address of the Xray droplet"
  value       = digitalocean_droplet.xray.ipv6_address
}

output "droplet_id" {
  description = "ID of the Xray droplet"
  value       = digitalocean_droplet.xray.id
}

output "ssh_command" {
  description = "SSH command to connect to the droplet"
  value       = "ssh root@${digitalocean_droplet.xray.ipv4_address}"
}

output "xray_config_info" {
  description = "Information about Xray configuration"
  value = {
    port        = var.xray_port
    server_name = var.xray_server_name
    address     = digitalocean_droplet.xray.ipv4_address
    note        = "Client configuration is available in /root/xray-client.txt on the server"
  }
}

output "firewall_id" {
  description = "ID of the firewall attached to the droplet"
  value       = digitalocean_firewall.xray.id
}

