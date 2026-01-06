#!/usr/bin/env bash
set -euo pipefail
echo "[xray-update] Starting Xray update..."
arch="linux-64"
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

echo "[xray-update] Fetching latest release tag..."
tag=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name // empty')
if [ -z "$tag" ] || [ "$tag" = "null" ]; then
  echo "[xray-update] ERROR: Failed to determine Xray release tag" >&2
  exit 1
fi
echo "[xray-update] Latest tag: $tag"

current=""
if [ -f /usr/local/share/xray/version ]; then
  current=$(cat /usr/local/share/xray/version)
  echo "[xray-update] Current version: $current"
else
  echo "[xray-update] No current version found, will install"
fi

if [ "$tag" = "$current" ]; then
  echo "[xray-update] Already up to date, skipping"
  exit 0
fi

echo "[xray-update] Downloading Xray $tag..."
url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-${arch}.zip"
if ! curl -fsSL "$url" -o "$tmpdir/xray.zip"; then
  echo "[xray-update] ERROR: Failed to download Xray" >&2
  exit 1
fi

echo "[xray-update] Extracting..."
if ! unzip -q "$tmpdir/xray.zip" -d "$tmpdir"; then
  echo "[xray-update] ERROR: Failed to extract Xray" >&2
  exit 1
fi

echo "[xray-update] Installing files..."
install -d /usr/local/bin /usr/local/share/xray
install -m 755 "$tmpdir/xray" /usr/local/bin/xray
install -m 644 "$tmpdir/geoip.dat" /usr/local/share/xray/geoip.dat
install -m 644 "$tmpdir/geosite.dat" /usr/local/share/xray/geosite.dat
echo "$tag" > /usr/local/share/xray/version

echo "[xray-update] Verifying installation..."
if /usr/local/bin/xray version > /dev/null 2>&1; then
  echo "[xray-update] Successfully installed Xray $tag"
else
  echo "[xray-update] ERROR: Xray installation verification failed" >&2
  exit 1
fi

