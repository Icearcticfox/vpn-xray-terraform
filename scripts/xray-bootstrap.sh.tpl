#!/usr/bin/env bash
set -euo pipefail

echo "[xray-bootstrap] Starting Xray bootstrap..."
XRAY_PORT=${xray_port}
XRAY_SERVER_NAME="${xray_server_name}"
echo "[xray-bootstrap] Port: $${XRAY_PORT}, Server Name: $${XRAY_SERVER_NAME}"

echo "[xray-bootstrap] Updating Xray..."
if ! /usr/local/bin/xray-update; then
  echo "[xray-bootstrap] ERROR: Failed to update Xray" >&2
  exit 1
fi

if [ ! -f /etc/xray/config.json ]; then
  echo "[xray-bootstrap] Generating new configuration..."
  uuid=$(cat /proc/sys/kernel/random/uuid)
  echo "[xray-bootstrap] Generated UUID: $${uuid:0:8}..."
  
  echo "[xray-bootstrap] Generating X25519 keys..."
  if ! keys=$(/usr/local/bin/xray x25519 2>&1); then
    echo "[xray-bootstrap] ERROR: Failed to generate X25519 keys" >&2
    echo "[xray-bootstrap] Xray output: $keys" >&2
    exit 1
  fi
  private_key=$(echo "$keys" | awk '/Private key/ {print $3}')
  public_key=$(echo "$keys" | awk '/Public key/ {print $3}')
  echo "[xray-bootstrap] Generated keys: Public=$${public_key:0:16}..."
  
  short_id=$(openssl rand -hex 8)
  echo "[xray-bootstrap] Generated Short ID: $${short_id}"

  mkdir -p /etc/xray

  # Generate config using jq to avoid YAML parsing issues
  jq -n \
    --argjson port "$${XRAY_PORT}" \
    --arg uuid "$${uuid}" \
    --arg server_name "$${XRAY_SERVER_NAME}" \
    --arg private_key "$${private_key}" \
    --arg short_id "$${short_id}" \
    '{
      "log": {
        "loglevel": "warning"
      },
      "inbounds": [
        {
          "listen": "0.0.0.0",
          "port": $port,
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid,
                "flow": "xtls-rprx-vision"
              }
            ],
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
        }
      ],
      "outbounds": [
        {
          "protocol": "freedom",
          "tag": "direct"
        }
      ]
    }' > /etc/xray/config.json

  # Save credentials for Terraform to generate client configs
  echo "[xray-bootstrap] Saving credentials..."
  jq -n \
    --arg uuid "$${uuid}" \
    --arg public_key "$${public_key}" \
    --arg short_id "$${short_id}" \
    '{
      "uuid": $uuid,
      "public_key": $public_key,
      "short_id": $short_id
    }' > /root/xray-credentials.json
  echo "[xray-bootstrap] Configuration saved successfully"
else
  echo "[xray-bootstrap] Configuration already exists, skipping generation"
fi

echo "[xray-bootstrap] Bootstrap completed successfully"

