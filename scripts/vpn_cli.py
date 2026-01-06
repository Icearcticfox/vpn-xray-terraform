#!/usr/bin/env python3
"""
vpn_cli - repo CLI (generate VLESS Reality link + QR, optionally send to Telegram).

Commands:

  1) qr
     Generate vless:// link + QR from local Xray server config JSON.

     python3 scripts/vpn_cli.py qr ./server-config.json --server 203.0.113.10 --out vless.png --print-link

  2) generate
     Download /etc/xray/config.json via SSH, generate link+QR, and optionally send to Telegram.

     python3 scripts/vpn_cli.py generate \
       --server 203.0.113.10 \
       --ssh-private-key "$SSH_PRIVATE_KEY" \
       --telegram-bot-token "$TELEGRAM_BOT_TOKEN" \
       --telegram-chat-id "$TELEGRAM_CHAT_ID" \
       --print-link
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import NoReturn, Optional
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import xray_reality_qr


class UserError(RuntimeError):
    pass


def die(msg: str, code: int = 2) -> NoReturn:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(code)


def run(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        raise UserError(f"Command failed: {' '.join(cmd)}\n{proc.stdout}")


def scp_download(server: str, key_path: Path, remote_path: str, local_path: Path) -> None:
    cmd = [
        "scp",
        "-i",
        str(key_path),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=10",
        f"root@{server}:{remote_path}",
        str(local_path),
    ]
    run(cmd)


def tg_send_message(bot_token: str, chat_id: str, text: str) -> None:
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    data = urlencode({"chat_id": chat_id, "text": text}).encode("utf-8")
    req = Request(url, data=data, method="POST")
    with urlopen(req, timeout=20) as resp:
        if resp.status >= 300:
            raise UserError(f"Telegram sendMessage failed: HTTP {resp.status}")


def _multipart_form(fields: dict[str, str], files: dict[str, Path]) -> tuple[bytes, str]:
    boundary = "----vpnxrayformboundary"
    lines: list[bytes] = []

    def add(b: bytes) -> None:
        lines.append(b)

    for name, value in fields.items():
        add(f"--{boundary}\r\n".encode())
        add(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        add(value.encode("utf-8"))
        add(b"\r\n")

    for name, path in files.items():
        filename = path.name
        ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        add(f"--{boundary}\r\n".encode())
        add(f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode())
        add(f"Content-Type: {ctype}\r\n\r\n".encode())
        add(path.read_bytes())
        add(b"\r\n")

    add(f"--{boundary}--\r\n".encode())
    body = b"".join(lines)
    return body, boundary


def tg_send_photo(bot_token: str, chat_id: str, photo_path: Path, caption: str = "") -> None:
    url = f"https://api.telegram.org/bot{bot_token}/sendPhoto"
    body, boundary = _multipart_form(
        fields={"chat_id": chat_id, "caption": caption},
        files={"photo": photo_path},
    )
    req = Request(url, data=body, method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    with urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise UserError(f"Telegram sendPhoto failed: HTTP {resp.status}")


def _download_latest_xray_linux_64(dest_dir: Path) -> Path:
    api = "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    with urlopen(Request(api, headers={"Accept": "application/vnd.github+json"}), timeout=20) as resp:
        if resp.status >= 300:
            raise UserError(f"Failed to query Xray latest release: HTTP {resp.status}")
        data = json.loads(resp.read().decode("utf-8"))
    tag = data.get("tag_name")
    if not isinstance(tag, str) or not tag.strip():
        raise UserError("Failed to parse tag_name from GitHub releases API")
    tag = tag.strip()

    url = f"https://github.com/XTLS/Xray-core/releases/download/{tag}/Xray-linux-64.zip"
    zip_path = dest_dir / "xray.zip"
    with urlopen(Request(url), timeout=60) as resp:
        if resp.status >= 300:
            raise UserError(f"Failed to download xray zip: HTTP {resp.status}")
        zip_path.write_bytes(resp.read())

    with zipfile.ZipFile(zip_path) as z:
        z.extract("xray", path=dest_dir)
    xray_path = dest_dir / "xray"
    os.chmod(xray_path, 0o755)
    return xray_path


def _ensure_xray_available() -> None:
    # Respect XRAY_BIN if set; otherwise require xray in PATH or download temporary xray.
    if os.environ.get("XRAY_BIN", "").strip():
        return
    if shutil_which("xray"):
        return
    tmp = Path(tempfile.mkdtemp(prefix="xray-bin-"))
    xray_path = _download_latest_xray_linux_64(tmp)
    os.environ["XRAY_BIN"] = str(xray_path)


def shutil_which(cmd: str) -> Optional[str]:
    path = os.environ.get("PATH", "")
    for p in path.split(os.pathsep):
        c = Path(p) / cmd
        if c.exists() and os.access(c, os.X_OK):
            return str(c)
    return None


def cmd_qr(args: argparse.Namespace) -> int:
    _ensure_xray_available()
    cfg_any = xray_reality_qr._load_json(args.config)  # type: ignore[attr-defined]
    cfg = xray_reality_qr._expect_dict(cfg_any, "root")  # type: ignore[attr-defined]
    inbound = xray_reality_qr._select_inbound(cfg, args.inbound_index)  # type: ignore[attr-defined]
    public_key = xray_reality_qr.compute_public_key_from_private(inbound.private_key)
    link = xray_reality_qr.build_vless_link(args.server, args.name, args.fp, inbound, public_key)

    if args.dry_run:
        print(link)
        return 0

    xray_reality_qr.qr_png(link, args.out)
    if args.print_link:
        print(link)
    if args.print_qr:
        xray_reality_qr.qr_ansi(link)
    return 0


def cmd_generate(args: argparse.Namespace) -> int:
    _ensure_xray_available()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    qr_path = out_dir / args.out_png

    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write(args.ssh_private_key)
        f.write("\n")
        key_path = Path(f.name)
    os.chmod(key_path, 0o600)

    try:
        local_cfg = out_dir / "server-config.json"
        scp_download(args.server, key_path, args.remote_config_path, local_cfg)

        cfg_any = xray_reality_qr._load_json(local_cfg)  # type: ignore[attr-defined]
        cfg = xray_reality_qr._expect_dict(cfg_any, "root")  # type: ignore[attr-defined]
        inbound = xray_reality_qr._select_inbound(cfg, args.inbound_index)  # type: ignore[attr-defined]
        public_key = xray_reality_qr.compute_public_key_from_private(inbound.private_key)
        link = xray_reality_qr.build_vless_link(args.server, args.name, args.fp, inbound, public_key)

        xray_reality_qr.qr_png(link, qr_path)

        if args.print_link:
            print(link)

        if args.telegram_bot_token and args.telegram_chat_id:
            tg_send_message(args.telegram_bot_token, args.telegram_chat_id, f"VLESS Reality link:\n{link}")
            tg_send_photo(args.telegram_bot_token, args.telegram_chat_id, qr_path, caption="VLESS Reality QR")

        return 0
    finally:
        try:
            key_path.unlink(missing_ok=True)
        except Exception:
            pass


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="vpn_cli", description="VPN/Xray helper CLI for this repo")
    sub = p.add_subparsers(dest="cmd", required=True)

    qr = sub.add_parser("qr", help="Generate vless link + QR from local server config JSON")
    qr.add_argument("config", type=Path, help="Path to Xray server config.json")
    qr.add_argument("--server", required=True, help="Public server host/IP used in the link")
    qr.add_argument("--name", default="reality-443", help="URL fragment (#name). Default: reality-443")
    qr.add_argument("--fp", default="chrome", help="Fingerprint (fp=). Default: chrome")
    qr.add_argument("--out", type=Path, default=Path("vless.png"), help="PNG output filename. Default: vless.png")
    qr.add_argument("--print-link", action="store_true")
    qr.add_argument("--print-qr", action="store_true")
    qr.add_argument("--dry-run", action="store_true")
    qr.add_argument("--inbound-index", type=int, default=None)
    qr.set_defaults(func=cmd_qr)

    gen = sub.add_parser("generate", help="Download server config via SSH and send link+QR to Telegram")
    gen.add_argument("--server", required=True, help="Public server host/IP used in the link")
    gen.add_argument("--ssh-private-key", required=True, help="SSH private key content (OpenSSH format)")
    gen.add_argument("--remote-config-path", default="/etc/xray/config.json", help="Remote path to Xray config.json")
    gen.add_argument("--out-dir", default="generated", help="Output directory. Default: generated")
    gen.add_argument("--out-png", default="vless.png", help="QR PNG filename inside out-dir. Default: vless.png")
    gen.add_argument("--name", default="reality-443", help="URL fragment (#name). Default: reality-443")
    gen.add_argument("--fp", default="chrome", help="Fingerprint (fp=). Default: chrome")
    gen.add_argument("--print-link", action="store_true", help="Print vless:// link to stdout")
    gen.add_argument("--inbound-index", type=int, default=None)
    gen.add_argument("--telegram-bot-token", default="", help="Telegram bot token (optional)")
    gen.add_argument("--telegram-chat-id", default="", help="Telegram chat id or @channel (optional)")
    gen.set_defaults(func=cmd_generate)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except UserError as e:
        die(str(e), code=2)


