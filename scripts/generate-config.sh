#!/usr/bin/env bash
set -euo pipefail

# Script to generate Xray client configuration and send to Telegram
# Usage: ./generate-config.sh <server_ip> <xray_port> <xray_server_name> <ssh_private_key> <telegram_bot_token> <telegram_chat_id>

SERVER_IP="${1}"
XRAY_PORT="${2}"
XRAY_SERVER_NAME="${3}"
SSH_PRIVATE_KEY="${4}"
TELEGRAM_BOT_TOKEN="${5:-}"
TELEGRAM_CHAT_ID="${6:-}"

echo "[INFO] Starting client configuration generation..."
echo "[INFO] Server IP: $SERVER_IP"
echo "[INFO] Xray Port: $XRAY_PORT"
echo "[INFO] Server Name: $XRAY_SERVER_NAME"

# Setup SSH key
SSH_KEY_PATH=$(mktemp)
echo "$SSH_PRIVATE_KEY" > "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
trap "rm -f $SSH_KEY_PATH" EXIT

# Wait for droplet to be ready (initial sleep)
echo "[INFO] Waiting for droplet to initialize (60 seconds)..."
sleep 60

# Wait for cloud-init to complete
echo "[INFO] Waiting for cloud-init to complete..."
MAX_CLOUD_INIT_ATTEMPTS=30
CLOUD_INIT_ATTEMPT=0
while [ $CLOUD_INIT_ATTEMPT -lt $MAX_CLOUD_INIT_ATTEMPTS ]; do
  STATUS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null root@"$SERVER_IP" "cloud-init status 2>/dev/null | head -1" || echo "unknown")
  echo "[INFO] Cloud-init attempt $((CLOUD_INIT_ATTEMPT + 1))/$MAX_CLOUD_INIT_ATTEMPTS - Status: $STATUS"
  
  if echo "$STATUS" | grep -q "status: done"; then
    echo "[SUCCESS] Cloud-init completed!"
    # Show last lines of cloud-init logs
    echo ""
    echo "=== Cloud-init logs (last 30 lines) ==="
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "tail -30 /var/log/cloud-init-output.log 2>/dev/null || tail -30 /var/log/cloud-init.log 2>/dev/null || echo 'Logs not available yet'"
    echo ""
    break
  fi
  CLOUD_INIT_ATTEMPT=$((CLOUD_INIT_ATTEMPT + 1))
  sleep 5
done

# Wait for xray-bootstrap to complete and credentials file to be created
echo "[INFO] Waiting for xray-credentials.json to be created..."
MAX_ATTEMPTS=60
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null root@"$SERVER_IP" "test -f /root/xray-credentials.json" 2>/dev/null; then
    echo "[SUCCESS] xray-credentials.json found!"
    break
  fi
  
  # Show progress and status every 5 attempts
  if [ $((ATTEMPT % 5)) -eq 0 ] && [ $ATTEMPT -gt 0 ]; then
    echo ""
    echo "[INFO] === Checking server status (attempt $ATTEMPT) ==="
    echo "[INFO] Checking if Xray binary exists..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "test -f /usr/local/bin/xray && echo '✓ Xray binary exists' || echo '✗ Xray binary NOT found'" || true
    echo "[INFO] Checking Xray version..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "/usr/local/bin/xray version 2>&1 | head -3 || echo 'Xray not executable'" || true
    echo "[INFO] Checking if config exists..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "test -f /etc/xray/config.json && echo '✓ Config exists' || echo '✗ Config NOT found'" || true
    echo "[INFO] Checking Xray service status..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "systemctl is-active xray.service 2>&1 || systemctl status xray.service --no-pager -l 2>&1 | head -10 || echo 'Service check failed'" || true
    echo "[INFO] Checking bootstrap log (last 10 lines)..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "tail -10 /var/log/xray-bootstrap.log 2>/dev/null || echo 'No bootstrap log yet'" || true
    echo ""
  fi
  
  ATTEMPT=$((ATTEMPT + 1))
  echo "[INFO] Attempt $ATTEMPT/$MAX_ATTEMPTS: waiting for credentials file..."
  sleep 5
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
  echo "[ERROR] xray-credentials.json was not created after $MAX_ATTEMPTS attempts"
  echo ""
  echo "=== Cloud-init status ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "cloud-init status || true"
  echo ""
  echo "=== Cloud-init logs (last 50 lines) ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "tail -50 /var/log/cloud-init-output.log || tail -50 /var/log/cloud-init.log || echo 'No cloud-init logs found'"
  echo ""
  echo "=== Xray bootstrap logs (full) ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "test -f /var/log/xray-bootstrap.log && cat /var/log/xray-bootstrap.log || echo 'No xray-bootstrap.log found'"
  echo ""
  echo "=== Xray binary check ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "ls -la /usr/local/bin/xray 2>&1 || echo 'Binary not found'; /usr/local/bin/xray version 2>&1 || echo 'Version check failed'"
  echo ""
  echo "=== Xray service status ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "systemctl status xray.service --no-pager -l || true"
  echo ""
  echo "=== Xray service logs (last 30 lines) ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "journalctl -u xray.service -n 30 --no-pager || true"
  echo ""
  echo "=== /root directory contents ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "ls -la /root/ || true"
  echo ""
  echo "=== /etc/xray directory contents ==="
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "ls -la /etc/xray/ 2>&1 || true"
  exit 1
fi

# Show final status after credentials are found
echo ""
echo "[INFO] === Final server status check ==="
echo "[INFO] Xray binary:"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "/usr/local/bin/xray version 2>&1 || echo 'Version check failed'" || true
echo "[INFO] Xray service status:"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "systemctl is-active xray.service && echo '✓ Service is active' || echo '✗ Service is NOT active'; systemctl status xray.service --no-pager -l 2>&1 | head -15 || true" || true
echo "[INFO] Xray listening on port:"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "ss -tlnp | grep :$XRAY_PORT || echo 'Port not listening'" || true
echo ""

# Copy credentials file from server
echo "[INFO] Copying credentials file from server..."
CREDENTIALS_FILE=$(mktemp)
if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP" "test -f /root/xray-credentials.json" 2>/dev/null; then
  scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER_IP":/root/xray-credentials.json "$CREDENTIALS_FILE"
  echo "[SUCCESS] Credentials file copied successfully"
else
  echo "[ERROR] xray-credentials.json not found on server"
  exit 1
fi

# Extract credentials
uuid=$(jq -r '.uuid' "$CREDENTIALS_FILE")
public_key=$(jq -r '.public_key' "$CREDENTIALS_FILE")
short_id=$(jq -r '.short_id' "$CREDENTIALS_FILE")
uuid_preview=$(echo "$uuid" | cut -c1-8)
public_key_preview=$(echo "$public_key" | cut -c1-16)
echo "[INFO] Extracted credentials: UUID=${uuid_preview}..., Public Key=${public_key_preview}..., Short ID=$short_id"

# Generate text config
TEXT_CONFIG=$(mktemp)
cat > "$TEXT_CONFIG" <<TXT
Xray VLESS Reality
Address: $SERVER_IP
Port: $XRAY_PORT
UUID: $uuid
Flow: xtls-rprx-vision
Server Name: $XRAY_SERVER_NAME
Public Key: $public_key
Short ID: $short_id
Security: reality
Network: tcp
TXT

# Generate JSON config
JSON_CONFIG=$(mktemp)
jq -n \
  --arg server_ip "$SERVER_IP" \
  --argjson xray_port "$XRAY_PORT" \
  --arg uuid "$uuid" \
  --arg xray_server_name "$XRAY_SERVER_NAME" \
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
  }' > "$JSON_CONFIG"

echo "[SUCCESS] Client configuration files generated:"
echo "  - Text config: $TEXT_CONFIG"
echo "  - JSON config: $JSON_CONFIG"

# Copy configs to server
echo "[INFO] Copying configs to server..."
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$TEXT_CONFIG" root@"$SERVER_IP":/root/xray-client.txt
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$JSON_CONFIG" root@"$SERVER_IP":/root/xray-client.json
echo "[SUCCESS] Configs copied to server"

# Send to Telegram if configured
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  echo "[INFO] Sending configuration to Telegram..."
  
  message="🔐 *Xray VPN Configuration*

*Server:* \`$SERVER_IP\`
*Port:* \`$XRAY_PORT\`
*Protocol:* VLESS Reality

\`\`\`
UUID: $uuid
Flow: xtls-rprx-vision
Server Name: $XRAY_SERVER_NAME
Public Key: $public_key
Short ID: $short_id
Security: reality
Network: tcp
\`\`\`

_Configuration saved to /root/ on server_"
  
  # Escape message for JSON
  message_escaped=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
  
  # Send text message
  if curl -fsSL -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"$message_escaped\", \"parse_mode\": \"Markdown\"}" > /dev/null 2>&1; then
    echo "[SUCCESS] Text message sent to Telegram"
  else
    echo "[WARNING] Failed to send text message to Telegram"
  fi
  
  # Send JSON file
  if curl -fsSL -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "document=@${JSON_CONFIG}" \
    -F "caption=📄 Xray Client Configuration (JSON)" > /dev/null 2>&1; then
    echo "[SUCCESS] JSON file sent to Telegram"
  else
    echo "[WARNING] Failed to send JSON file to Telegram"
  fi
else
  echo "[INFO] Telegram not configured, skipping notification"
fi

# Cleanup
rm -f "$CREDENTIALS_FILE" "$TEXT_CONFIG" "$JSON_CONFIG"

echo "[SUCCESS] Client configuration generation completed!"

