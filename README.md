# vpn-xray-terraform

Terraform project that provisions a minimal DigitalOcean droplet (Terraform) and installs Xray (VLESS Reality) in a separate CI job.

## Features

- ✅ Automated droplet + firewall provisioning
- ✅ Xray installation via CI job (SSH)
- ✅ DigitalOcean firewall configuration for security
- ✅ Configurable Xray port and server name via variables
- ✅ SSH access control via firewall rules
- ✅ Comprehensive outputs (IP addresses, SSH command, config info)

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
- `xray_server_name` - Xray Reality server name/SNI (default: `www.ozon.ru`)
- `allowed_ssh_ips` - List of IP addresses/CIDR blocks allowed to SSH (default: `["0.0.0.0/0", "::/0"]`)

### Example: Custom Configuration

```hcl
terraform apply \
  -var="xray_port=8443" \
  -var="xray_server_name=www.ozon.ru" \
  -var='allowed_ssh_ips=["1.2.3.4/32"]'
```

### Telegram Integration (Optional)

To automatically send the VLESS Reality share link + QR to a Telegram channel:

1. **Create a Telegram Bot:**
   - Talk to [@BotFather](https://t.me/BotFather) on Telegram
   - Send `/newbot` and follow instructions
   - Copy the bot token (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

2. **Get Chat ID:**
   - For a channel: Add bot as admin, then send a message to the channel
   - Get chat ID using: `https://api.telegram.org/bot<TOKEN>/getUpdates`
   - Look for `"chat":{"id":-1001234567890}` (negative number for channels)
   - Or use channel username: `@your_channel_name`

3. **For GitHub Actions:**
   Add secrets:
   - `TELEGRAM_BOT_TOKEN` - Bot token
   - `TELEGRAM_CHAT_ID` - Chat ID or channel username

   The link + QR will be automatically sent to Telegram after the server is deployed.

## Outputs

After applying, Terraform will output:

- `droplet_ip` - Public IPv4 address
- `droplet_ipv6` - Public IPv6 address
- `droplet_id` - Droplet ID
- `ssh_command` - Ready-to-use SSH command
- `xray_config_info` - Xray configuration details
- `firewall_id` - Firewall ID

## Client Configuration

After the server is deployed, a VLESS Reality share link and QR code are generated and sent to Telegram (if configured).

1. **Telegram (recommended):**
   - The `vless://` share link is sent as a message
   - A QR code PNG is sent as an image

1. **Manual generation (local):**

```bash
ssh root@$(terraform output -raw droplet_ip) 'cat /etc/xray/config.json' > server-config.json
python3 -m pip install -r requirements.txt
python3 ./scripts/vpn_cli.py qr ./server-config.json --server "$(terraform output -raw droplet_ip)" --print-link --out vless.png
```

1. **Client Applications:**
   - **Windows**: [v2rayN](https://github.com/2dust/v2rayN) or [Qv2ray](https://github.com/Qv2ray/Qv2ray)
   - **Android**: [v2rayNG](https://github.com/2dust/v2rayNG) (Google Play / F-Droid)
   - **iOS**: Shadowrocket or Stash (App Store, paid)
   - **macOS**: [v2rayU](https://github.com/yanue/V2rayU) or Qv2ray
   - **Linux**: Qv2ray or Xray-core CLI

## Xray Notes

- The server config is stored at `/etc/xray/config.json`.
- Uses **WebSocket (ws)** transport protocol for better compatibility.
- Uses **Reality** security with Russian SNI (`www.ozon.ru` by default) for better performance in Russia.
- The CI workflow generates a VLESS Reality share link + QR and sends them to Telegram (if configured).
- To change the port or Reality server name, update Terraform variables and re-run the pipeline.

## Security

The firewall automatically:

- Restricts SSH access to specified IP addresses (configurable via `allowed_ssh_ips`)
- Allows inbound traffic on the Xray port from anywhere
- Allows all outbound traffic for normal operation

## GitHub Actions

The workflow consists of two jobs that run automatically:

1. **terraform** - Creates infrastructure (droplet + firewall)
   - Runs on: Pull Requests (plan only) and Push to master (apply)
   - Exposes outputs: droplet_ip, xray_port, xray_server_name

2. **install-xray** - Installs Xray via Ansible
   - Runs on: Push to master (after terraform job succeeds)

3. **generate-config** - Generates client configuration and sends to Telegram
   - Runs on: Push to master (after terraform job succeeds; you can make it depend on install-xray if needed)

### Required GitHub Secrets

Add these secrets in your repository (Settings → Secrets and variables → Actions):

1. **DIGITAL_OCEAN** - DigitalOcean API token
   - Generate at: [DigitalOcean API tokens](https://cloud.digitalocean.com/account/api/tokens)

2. **ICEFOX_FINGERPRINT** - SSH key fingerprint from DigitalOcean
   - Find at: [DigitalOcean security](https://cloud.digitalocean.com/account/security)

3. **SSH_PRIVATE_KEY** - SSH private key content (the same key used in DigitalOcean)
   - Get your private key: `cat ~/.ssh/id_rsa` (or your key path)
   - Copy the entire key including `-----BEGIN ...-----` and `-----END ...-----`
   - Used by CI jobs to connect to the droplet

4. **TERRAFORM_XRAY** - Terraform Cloud user token
   - Generate at: [Terraform Cloud tokens](https://app.terraform.io/app/settings/tokens)
   - Token format: `atlasv1.xxx...`

### Optional GitHub Secrets (for Telegram notifications)

1. **TELEGRAM_BOT_TOKEN** - Telegram bot token (optional)
   - Create bot via [@BotFather](https://t.me/BotFather)

2. **TELEGRAM_CHAT_ID** - Telegram chat ID or channel username (optional)
   - Format: `-1001234567890` for channels or `@channel_name`

### Terraform Cloud Workspace

The workspace `vpn-xray-terraform` in organization `icefox_infra` will be created automatically on first `terraform init`, or you can create it manually in Terraform Cloud.
