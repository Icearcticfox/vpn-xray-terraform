# vpn-xray-terraform

Terraform project that provisions a minimal DigitalOcean droplet and installs Xray (VLESS Reality) via cloud-init.

## Features

- ✅ Automated Xray (VLESS Reality) server deployment
- ✅ DigitalOcean firewall configuration for security
- ✅ Configurable Xray port and server name via variables
- ✅ SSH access control via firewall rules
- ✅ Comprehensive outputs (IP addresses, SSH command, config info)
- ✅ Automatic Xray updates via systemd timer

## Prerequisites
- Terraform >= 1.7.0
- DigitalOcean API token and SSH key fingerprint
- Terraform Cloud workspace (required for remote state)

## Quick Start

### Local Setup
1) Export variables locally:
   - `export TF_VAR_do_token=...`
   - `export TF_VAR_ssh_key_fingerprint=...`
2) Initialize and apply:
   - `terraform init`
   - `terraform apply`

### GitHub Actions Setup
The Terraform Cloud backend is already configured for organization `icefox_infra`. Make sure to add these secrets in GitHub:
- `DIGITAL_OCEAN` - DigitalOcean API token
- `ICEFOX_FINGERPRINT` - SSH key fingerprint
- `TERRAFORM_XRAY` - Terraform Cloud user token (starts with `atlasv1.`)

## Variables

### Required Variables
- `do_token` - DigitalOcean API token
- `ssh_key_fingerprint` - Fingerprint of the SSH key uploaded to DigitalOcean

### Optional Variables
- `region` - DigitalOcean region (default: `fra1`)
- `size` - Droplet size slug (default: `s-1vcpu-512mb-10gb`)
- `droplet_name` - Droplet name (default: `xray-vpn`)
- `xray_port` - Xray server port (default: `443`)
- `xray_server_name` - Xray Reality server name/SNI (default: `www.cloudflare.com`)
- `allowed_ssh_ips` - List of IP addresses/CIDR blocks allowed to SSH (default: `["0.0.0.0/0", "::/0"]`)
- `telegram_bot_token` - Telegram bot token for sending client config (optional)
- `telegram_chat_id` - Telegram chat ID or channel username (e.g., `@channel` or `-1001234567890`)

### Example: Custom Configuration
```hcl
terraform apply \
  -var="xray_port=8443" \
  -var="xray_server_name=www.microsoft.com" \
  -var='allowed_ssh_ips=["1.2.3.4/32"]'
```

### Telegram Integration (Optional)

To automatically send client configuration to a Telegram channel:

1. **Create a Telegram Bot:**
   - Talk to [@BotFather](https://t.me/BotFather) on Telegram
   - Send `/newbot` and follow instructions
   - Copy the bot token (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

2. **Get Chat ID:**
   - For a channel: Add bot as admin, then send a message to the channel
   - Get chat ID using: `https://api.telegram.org/bot<TOKEN>/getUpdates`
   - Look for `"chat":{"id":-1001234567890}` (negative number for channels)
   - Or use channel username: `@your_channel_name`

3. **Configure in Terraform:**
   ```hcl
   terraform apply \
     -var="telegram_bot_token=123456789:ABCdefGHIjklMNOpqrsTUVwxyz" \
     -var="telegram_chat_id=-1001234567890"
   ```

   Or export as environment variables:
   ```bash
   export TF_VAR_telegram_bot_token="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
   export TF_VAR_telegram_chat_id="-1001234567890"
   ```

4. **For GitHub Actions:**
   Add secrets:
   - `TELEGRAM_BOT_TOKEN` - Bot token
   - `TELEGRAM_CHAT_ID` - Chat ID or channel username

   Then update workflow to include these variables.

## Outputs

After applying, Terraform will output:
- `droplet_ip` - Public IPv4 address
- `droplet_ipv6` - Public IPv6 address
- `droplet_id` - Droplet ID
- `ssh_command` - Ready-to-use SSH command
- `xray_config_info` - Xray configuration details
- `firewall_id` - Firewall ID

## Client Configuration

After the server is deployed, you need to get the client configuration:

1. **Get client data from server:**
   ```bash
   ssh root@$(terraform output -raw droplet_ip)
   cat /root/xray-client.txt          # Text format
   cat /root/xray-client.json          # JSON config (ready to use)
   ```

   **Or check Telegram channel** (if Telegram integration is configured):
   - Text configuration will be sent as a message
   - JSON configuration file will be sent as a document attachment
   - Both are automatically sent after server setup

2. **You'll get data like this:**
   ```
   Xray VLESS Reality
   Address: 123.45.67.89
   Port: 443
   UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   Flow: xtls-rprx-vision
   Server Name: www.cloudflare.com
   Public Key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   Short ID: xxxxxxxxxxxxxxxx
   Security: reality
   Network: tcp
   ```

3. **Client Applications:**
   - **Windows**: [v2rayN](https://github.com/2dust/v2rayN) or [Qv2ray](https://github.com/Qv2ray/Qv2ray)
   - **Android**: [v2rayNG](https://github.com/2dust/v2rayNG) (Google Play / F-Droid)
   - **iOS**: Shadowrocket or Stash (App Store, paid)
   - **macOS**: [v2rayU](https://github.com/yanue/V2rayU) or Qv2ray
   - **Linux**: Qv2ray or Xray-core CLI

4. **Using the Generated JSON Config:**
   
   A ready-to-use JSON configuration file is automatically generated at `/root/xray-client.json` on the server. This file includes:
   - SOCKS5 proxy on port `10808`
   - HTTP proxy on port `10809`
   - VLESS Reality outbound configuration
   - Routing rules for local networks
   
   **To use it:**
   - Download from Telegram (if configured) or copy from server
   - Import into your Xray client application
   - Or use directly with Xray-core CLI: `xray run -c xray-client.json`

5. **Manual Client Configuration Example (JSON):**
   ```json
   {
     "outbounds": [
       {
         "protocol": "vless",
         "settings": {
           "vnext": [
             {
               "address": "YOUR_SERVER_IP",
               "port": 443,
               "users": [
                 {
                   "id": "YOUR_UUID",
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
             "dest": "www.cloudflare.com:443",
             "xver": 0,
             "serverNames": ["www.cloudflare.com"],
             "publicKey": "YOUR_PUBLIC_KEY",
             "shortId": "YOUR_SHORT_ID"
           }
         }
       }
     ]
   }
   ```

   Replace placeholders with values from `/root/xray-client.txt`.

## Xray Notes
- The server config is created on first boot only.
- Client configuration files are generated:
  - `/root/xray-client.txt` - Human-readable text format
  - `/root/xray-client.json` - Ready-to-use JSON config for Xray clients
- Both files are automatically sent to Telegram (if configured).
- Xray auto-updates daily via a systemd timer (`xray-update.timer`).
- To change the port or Reality server name, update the variables and recreate the droplet.

## Security

The firewall automatically:
- Restricts SSH access to specified IP addresses (configurable via `allowed_ssh_ips`)
- Allows inbound traffic on the Xray port from anywhere
- Allows all outbound traffic for normal operation

## GitHub Actions

The workflow automatically runs on:
- **Pull Requests**: Validates and plans changes
- **Push to master**: Applies changes automatically

### Required GitHub Secrets

Add these secrets in your repository (Settings → Secrets and variables → Actions):

1. **DIGITAL_OCEAN** - DigitalOcean API token
   - Generate at: https://cloud.digitalocean.com/account/api/tokens

2. **ICEFOX_FINGERPRINT** - SSH key fingerprint from DigitalOcean
   - Find at: https://cloud.digitalocean.com/account/security

3. **SSH_PRIVATE_KEY** - SSH private key content (the same key used in DigitalOcean)
   - Get your private key: `cat ~/.ssh/id_rsa` (or path to your SSH key)
   - Copy the entire key including `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----`
   - This key is used by Terraform to connect to the droplet for configuration

4. **TERRAFORM_XRAY** - Terraform Cloud user token
   - Generate at: https://app.terraform.io/app/settings/tokens
   - Token format: `kIzz3FiqlAWhVg.atlasv1.xxx...`

### Optional GitHub Secrets (for Telegram notifications)

5. **TELEGRAM_BOT_TOKEN** - Telegram bot token (optional)
   - Create bot via [@BotFather](https://t.me/BotFather)

6. **TELEGRAM_CHAT_ID** - Telegram chat ID or channel username (optional)
   - Format: `-1001234567890` for channels or `@channel_name`

### Terraform Cloud Workspace

The workspace `vpn-xray-terraform` in organization `icefox_infra` will be created automatically on first `terraform init`, or you can create it manually in Terraform Cloud.
