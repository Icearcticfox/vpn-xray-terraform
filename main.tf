terraform {
  required_version = ">= 1.7.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.38"
    }
  }

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "icefox_infra"

    workspaces {
      name = "vpn-xray-terraform"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_droplet" "xray" {
  name      = var.droplet_name
  region    = var.region
  size      = var.size
  image     = "ubuntu-24-04-x64"
  ssh_keys  = [var.ssh_key_fingerprint]
  user_data = file("${path.module}/cloud-init.yaml")

  connection {
    type        = "ssh"
    host        = self.ipv4_address
    user        = "root"
    private_key = var.ssh_private_key != "" ? var.ssh_private_key : file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  # Install Xray
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo '[INFO] Installing Xray...'",
      "ARCH='linux-64'",
      "TAG=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')",
      "echo '[INFO] Latest Xray version: $TAG'",
      "curl -fsSL https://github.com/XTLS/Xray-core/releases/download/$TAG/Xray-$ARCH.zip -o /tmp/xray.zip",
      "unzip -q /tmp/xray.zip -d /tmp/xray",
      "install -d /usr/local/bin /usr/local/share/xray",
      "install -m 755 /tmp/xray/xray /usr/local/bin/xray",
      "install -m 644 /tmp/xray/geoip.dat /usr/local/share/xray/geoip.dat",
      "install -m 644 /tmp/xray/geosite.dat /usr/local/share/xray/geosite.dat",
      "rm -rf /tmp/xray /tmp/xray.zip",
      "echo '[SUCCESS] Xray installed'"
    ]
  }

  # Generate config and credentials
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo '[INFO] Generating Xray configuration...'",
      "UUID=$(cat /proc/sys/kernel/random/uuid)",
      "KEYS=$(/usr/local/bin/xray x25519)",
      "PRIVATE_KEY=$(echo \"$KEYS\" | awk '/Private key/ {print $3}')",
      "PUBLIC_KEY=$(echo \"$KEYS\" | awk '/Public key/ {print $3}')",
      "SHORT_ID=$(openssl rand -hex 8)",
      "mkdir -p /etc/xray",
      "jq -n --argjson port ${var.xray_port} --arg uuid \"$UUID\" --arg server_name \"${var.xray_server_name}\" --arg private_key \"$PRIVATE_KEY\" --arg short_id \"$SHORT_ID\" '{",
      "  \"log\": {\"loglevel\": \"warning\"},",
      "  \"inbounds\": [{",
      "    \"listen\": \"0.0.0.0\",",
      "    \"port\": $port,",
      "    \"protocol\": \"vless\",",
      "    \"settings\": {",
      "      \"clients\": [{\"id\": $uuid, \"flow\": \"xtls-rprx-vision\"}],",
      "      \"decryption\": \"none\"",
      "    },",
      "    \"streamSettings\": {",
      "      \"network\": \"tcp\",",
      "      \"security\": \"reality\",",
      "      \"realitySettings\": {",
      "        \"show\": false,",
      "        \"dest\": ($server_name + \":443\"),",
      "        \"xver\": 0,",
      "        \"serverNames\": [$server_name],",
      "        \"privateKey\": $private_key,",
      "        \"shortIds\": [$short_id]",
      "      }",
      "    }",
      "  }],",
      "  \"outbounds\": [{\"protocol\": \"freedom\", \"tag\": \"direct\"}]",
      "}' > /etc/xray/config.json",
      "jq -n --arg uuid \"$UUID\" --arg public_key \"$PUBLIC_KEY\" --arg short_id \"$SHORT_ID\" '{",
      "  \"uuid\": $uuid,",
      "  \"public_key\": $public_key,",
      "  \"short_id\": $short_id",
      "}' > /root/xray-credentials.json",
      "echo '[SUCCESS] Configuration generated'"
    ]
  }

  # Setup systemd service
  provisioner "file" {
    content = <<-EOT
[Unit]
Description=Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOT
    destination = "/etc/systemd/system/xray.service"
  }

  # Enable and start service
  provisioner "remote-exec" {
    inline = [
      "systemctl daemon-reload",
      "systemctl enable xray.service",
      "systemctl start xray.service",
      "sleep 2",
      "systemctl status xray.service --no-pager || true",
      "echo '[SUCCESS] Xray service started'"
    ]
  }
}

resource "digitalocean_firewall" "xray" {
  name = "${var.droplet_name}-firewall"

  droplet_ids = [digitalocean_droplet.xray.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.allowed_ssh_ips
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = tostring(var.xray_port)
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
