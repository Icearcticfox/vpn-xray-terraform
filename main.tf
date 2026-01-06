terraform {
  required_version = ">= 1.7.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.38"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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
  image     = "ubuntu-22-04-x64"
  ssh_keys  = [var.ssh_key_fingerprint]
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    xray_port        = var.xray_port
    xray_server_name = var.xray_server_name
  })
}

resource "null_resource" "generate_client_config" {
  depends_on = [digitalocean_droplet.xray]

  # Wait for cloud-init to complete and credentials file to be ready
  provisioner "local-exec" {
    command = <<-EOT
      # Create SSH key file if using ssh_private_key variable
      if [ -n "${var.ssh_private_key}" ]; then
        mkdir -p ~/.ssh
        echo "${var.ssh_private_key}" > ~/.ssh/id_rsa
        chmod 600 ~/.ssh/id_rsa
        SSH_KEY_PATH=~/.ssh/id_rsa
      else
        SSH_KEY_PATH=${pathexpand(var.ssh_private_key_path)}
      fi
      
      # Wait for droplet to be ready (initial sleep)
      echo "Waiting for droplet to initialize..."
      sleep 60
      
      # Wait for cloud-init to complete
      echo "Waiting for cloud-init to complete..."
      MAX_CLOUD_INIT_ATTEMPTS=30
      CLOUD_INIT_ATTEMPT=0
      while [ $CLOUD_INIT_ATTEMPT -lt $MAX_CLOUD_INIT_ATTEMPTS ]; do
        STATUS=$(ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null root@${digitalocean_droplet.xray.ipv4_address} "cloud-init status 2>/dev/null | head -1" || echo "unknown")
        echo "Cloud-init attempt $CLOUD_INIT_ATTEMPT/$MAX_CLOUD_INIT_ATTEMPTS - Status: $STATUS"
        
        if echo "$STATUS" | grep -q "status: done"; then
          echo "✓ Cloud-init completed!"
          # Show last lines of cloud-init logs
          echo ""
          echo "=== Cloud-init logs (last 30 lines) ==="
          ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "tail -30 /var/log/cloud-init-output.log 2>/dev/null || tail -30 /var/log/cloud-init.log 2>/dev/null || echo 'Logs not available yet'"
          echo ""
          break
        fi
        CLOUD_INIT_ATTEMPT=$((CLOUD_INIT_ATTEMPT + 1))
        sleep 5
      done
      
      # Wait for xray-bootstrap to complete and credentials file to be created
      echo "Waiting for xray-credentials.json to be created..."
      MAX_ATTEMPTS=60
      ATTEMPT=0
      while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        if ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null root@${digitalocean_droplet.xray.ipv4_address} "test -f /root/xray-credentials.json" 2>/dev/null; then
          echo "✓ xray-credentials.json found!"
          break
        fi
        ATTEMPT=$((ATTEMPT + 1))
        echo "Attempt $ATTEMPT/$MAX_ATTEMPTS: waiting for credentials file..."
        sleep 5
      done
      
      if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo "ERROR: xray-credentials.json was not created after $MAX_ATTEMPTS attempts"
        echo ""
        echo "=== Cloud-init status ==="
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "cloud-init status || true"
        echo ""
        echo "=== Cloud-init logs (last 50 lines) ==="
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "tail -50 /var/log/cloud-init-output.log || tail -50 /var/log/cloud-init.log || echo 'No cloud-init logs found'"
        echo ""
        echo "=== /root directory contents ==="
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "ls -la /root/ || true"
        echo ""
        echo "=== Checking xray-bootstrap process ==="
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "ps aux | grep -E 'xray|bootstrap' || true"
        echo ""
        echo "=== Checking if xray service exists ==="
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "systemctl status xray.service || true"
        echo ""
        echo "=== Checking xray-bootstrap script ==="
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "test -f /usr/local/bin/xray-bootstrap && echo 'xray-bootstrap exists' || echo 'xray-bootstrap NOT found'"
        echo ""
        echo "=== Checking xray config ==="
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "test -f /etc/xray/config.json && echo 'xray config exists' || echo 'xray config NOT found'"
        exit 1
      fi
      
      # Show some debug info even on success
      echo ""
      echo "=== Server status (for debugging) ==="
      ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "echo 'Cloud-init status:' && cloud-init status 2>/dev/null || echo 'N/A'; echo 'Xray service:' && systemctl is-active xray.service 2>/dev/null || echo 'N/A'"
    EOT
  }

  connection {
    type        = "ssh"
    host        = digitalocean_droplet.xray.ipv4_address
    user        = "root"
    private_key = var.ssh_private_key != "" ? var.ssh_private_key : file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  # Copy credentials file from server to local
  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/.terraform
      # Determine SSH key path (reuse from previous step)
      if [ -n "${var.ssh_private_key}" ]; then
        mkdir -p ~/.ssh
        echo "${var.ssh_private_key}" > ~/.ssh/id_rsa
        chmod 600 ~/.ssh/id_rsa
        SSH_KEY_PATH=~/.ssh/id_rsa
      else
        SSH_KEY_PATH=${pathexpand(var.ssh_private_key_path)}
      fi
      
      # Verify file exists before copying
      if ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "test -f /root/xray-credentials.json" 2>/dev/null; then
        scp -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address}:/root/xray-credentials.json ${path.module}/.terraform/xray-credentials.json
        echo "✓ Credentials file copied successfully"
      else
        echo "ERROR: xray-credentials.json not found on server"
        ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${digitalocean_droplet.xray.ipv4_address} "ls -la /root/ | head -20" || true
        exit 1
      fi
    EOT
  }

  # Generate client configs locally
  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}
      uuid=$(jq -r '.uuid' .terraform/xray-credentials.json)
      public_key=$(jq -r '.public_key' .terraform/xray-credentials.json)
      short_id=$(jq -r '.short_id' .terraform/xray-credentials.json)
      
      # Generate text config
      cat > .terraform/xray-client.txt <<TXT
Xray VLESS Reality
Address: ${digitalocean_droplet.xray.ipv4_address}
Port: ${var.xray_port}
UUID: $uuid
Flow: xtls-rprx-vision
Server Name: ${var.xray_server_name}
Public Key: $public_key
Short ID: $short_id
Security: reality
Network: tcp
TXT
      
      # Generate JSON config
      jq -n \
        --arg server_ip "${digitalocean_droplet.xray.ipv4_address}" \
        --argjson xray_port ${var.xray_port} \
        --arg uuid "$uuid" \
        --arg xray_server_name "${var.xray_server_name}" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        '{
          "log": {
            "loglevel": "warning"
          },
          "inbounds": [
            {
              "port": 10808,
              "protocol": "socks",
              "settings": {
                "udp": true
              },
              "tag": "socks-in"
            },
            {
              "port": 10809,
              "protocol": "http",
              "settings": {},
              "tag": "http-in"
            }
          ],
          "outbounds": [
            {
              "protocol": "vless",
              "settings": {
                "vnext": [
                  {
                    "address": $server_ip,
                    "port": $xray_port,
                    "users": [
                      {
                        "id": $uuid,
                        "flow": "xtls-rprx-vision",
                        "encryption": "none"
                      }
                    ]
                  }
                ]
              },
              "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                  "show": false,
                  "dest": ($xray_server_name + ":443"),
                  "xver": 0,
                  "serverNames": [$xray_server_name],
                  "publicKey": $public_key,
                  "shortId": $short_id
                }
              },
              "tag": "proxy"
            },
            {
              "protocol": "freedom",
              "tag": "direct"
            }
          ],
          "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
              {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "direct"
              }
            ]
          }
        }' > .terraform/xray-client.json
    EOT
  }

  # Copy generated configs to server
  provisioner "file" {
    source      = "${path.module}/.terraform/xray-client.txt"
    destination = "/root/xray-client.txt"
  }

  provisioner "file" {
    source      = "${path.module}/.terraform/xray-client.json"
    destination = "/root/xray-client.json"
  }

  # Send to Telegram if configured
  provisioner "remote-exec" {
    inline = [
      "if [ -n \"${var.telegram_bot_token}\" ] && [ -n \"${var.telegram_chat_id}\" ]; then",
      "  uuid=$(jq -r '.uuid' /root/xray-credentials.json)",
      "  public_key=$(jq -r '.public_key' /root/xray-credentials.json)",
      "  short_id=$(jq -r '.short_id' /root/xray-credentials.json)",
      "  message=\"🔐 *Xray VPN Configuration*\\n\\n*Server:* \\`${digitalocean_droplet.xray.ipv4_address}\\`\\n*Port:* \\`${var.xray_port}\\`\\n*Protocol:* VLESS Reality\\n\\n\\`\\`\\`\\nUUID: $uuid\\nFlow: xtls-rprx-vision\\nServer Name: ${var.xray_server_name}\\nPublic Key: $public_key\\nShort ID: $short_id\\nSecurity: reality\\nNetwork: tcp\\n\\`\\`\\`\\n\\n_Configuration saved to /root/ on server_\"",
      "  message_escaped=$(echo \"$message\" | sed 's/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g; s/$/\\\\n/' | tr -d '\\n' | sed 's/\\\\n$//')",
      "  curl -fsSL -X POST \"https://api.telegram.org/bot${var.telegram_bot_token}/sendMessage\" \\",
      "    -H \"Content-Type: application/json\" \\",
      "    -d \"{\\\"chat_id\\\": \\\"${var.telegram_chat_id}\\\", \\\"text\\\": \\\"$message_escaped\\\", \\\"parse_mode\\\": \\\"Markdown\\\"}\" > /dev/null 2>&1 || true",
      "  curl -fsSL -X POST \"https://api.telegram.org/bot${var.telegram_bot_token}/sendDocument\" \\",
      "    -F \"chat_id=${var.telegram_chat_id}\" \\",
      "    -F \"document=@/root/xray-client.json\" \\",
      "    -F \"caption=📄 Xray Client Configuration (JSON)\" > /dev/null 2>&1 || true",
      "fi"
    ]
  }

  triggers = {
    droplet_ip = digitalocean_droplet.xray.ipv4_address
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
