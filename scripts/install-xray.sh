#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="$1"
XRAY_PORT="$2"
XRAY_SERVER_NAME="$3"
SSH_PRIVATE_KEY="$4"

echo "[INFO] Installing Xray on $SERVER_IP..."

# Setup SSH key
SSH_KEY_PATH=$(mktemp)
echo "$SSH_PRIVATE_KEY" > "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
trap "rm -f $SSH_KEY_PATH" EXIT

# Wait for droplet SSH
echo "[INFO] Waiting for droplet SSH..."
for i in {1..30}; do
  if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$SERVER_IP" "echo OK" 2>/dev/null; then
    echo "[SUCCESS] Droplet is reachable"
    break
  fi
  echo "[INFO] Attempt $i/30..."
  sleep 5
done

# Single remote script: install, configure, start
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no root@"$SERVER_IP" bash -s <<EOF
set -e
XRAY_PORT="$XRAY_PORT"
XRAY_SERVER_NAME="$XRAY_SERVER_NAME"

echo "[INFO] Installing packages..."
apt-get update -qq
apt-get install -y -qq curl unzip jq

echo "[INFO] Downloading Xray..."
ARCH="linux-64"
TAG=\$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/\$TAG/Xray-\$ARCH.zip" -o /tmp/xray.zip
unzip -q /tmp/xray.zip -d /tmp/xray
install -d /usr/local/bin /usr/local/share/xray
install -m 755 /tmp/xray/xray /usr/local/bin/xray
install -m 644 /tmp/xray/geoip.dat /usr/local/share/xray/geoip.dat
install -m 644 /tmp/xray/geosite.dat /usr/local/share/xray/geosite.dat
rm -rf /tmp/xray /tmp/xray.zip
echo "[SUCCESS] Xray installed"

echo "[INFO] Generating config..."
UUID=\$(cat /proc/sys/kernel/random/uuid)
KEYS=\$(/usr/local/bin/xray x25519)
PRIVATE_KEY=\$(echo "\$KEYS" | awk '/Private key/ {print \$3}')
PUBLIC_KEY=\$(echo "\$KEYS" | awk '/Public key/ {print \$3}')
SHORT_ID=\$(openssl rand -hex 8)

mkdir -p /etc/xray
jq -n \\
  --argjson port "\$XRAY_PORT" \\
  --arg uuid "\$UUID" \\
  --arg server_name "\$XRAY_SERVER_NAME" \\
  --arg private_key "\$PRIVATE_KEY" \\
  --arg short_id "\$SHORT_ID" \\
  '{
    "log": {"loglevel": "warning"},
    "inbounds": [{
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": ($server_name + ":443"),
          "xver": 0,
          "serverNames": [$server_name],
          "privateKey": $private_key,
          "shortIds": [$short_id]
        }
      }
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}]
  }' > /etc/xray/config.json

jq -n \\
  --arg uuid "\$UUID" \\
  --arg public_key "\$PUBLIC_KEY" \\
  --arg short_id "\$SHORT_ID" \\
  '{ "uuid": $uuid, "public_key": $public_key, "short_id": $short_id }' > /root/xray-credentials.json

cat > /etc/systemd/system/xray.service <<'UNIT'
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
UNIT

systemctl daemon-reload
systemctl enable xray.service
systemctl start xray.service
sleep 2
systemctl is-active xray.service || systemctl status xray.service --no-pager || true
echo "[SUCCESS] Xray service started"
EOF

echo "[SUCCESS] Xray installation completed!"
