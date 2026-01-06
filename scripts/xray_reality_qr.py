#!/usr/bin/env python3
"""
xray_reality_qr - Generate VLESS Reality share link + QR from an Xray server config JSON.

Usage examples:

  # Generate QR PNG + print link
  python3 scripts/xray_reality_qr.py /path/to/config.json --server 203.0.113.10 --print-link --out vless.png

  # Choose a specific inbound
  python3 scripts/xray_reality_qr.py /path/to/config.json --server vpn.example.com --inbound-index 0 --print-link --print-qr

  # Dry run (no QR output)
  python3 scripts/xray_reality_qr.py /path/to/config.json --server 203.0.113.10 --dry-run

Link format (Reality/Vision):
vless://{uuid}@{server}:{port}?type={network}&security=reality&sni={sni}&fp={fp}&pbk={publicKey}&sid={shortId}{&flow=...}#{name}
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import uuid as uuid_lib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn, Optional
from urllib.parse import quote, urlencode


class UserError(RuntimeError):
    pass


@dataclass(frozen=True)
class RealityInbound:
    uuid: str
    flow: Optional[str]
    port: int
    network: str
    sni: str
    short_id: str
    private_key: str


_B64URL_RE = re.compile(r"^[A-Za-z0-9_-]{32,}$")
_HEX_RE = re.compile(r"^[0-9a-fA-F]+$")


def _die(msg: str, code: int = 2) -> NoReturn:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise UserError(f"Config file not found: {path}")
    except json.JSONDecodeError as e:
        raise UserError(f"Invalid JSON in {path}: {e}")


def _expect_dict(v: Any, where: str) -> dict[str, Any]:
    if not isinstance(v, dict):
        raise UserError(f"Expected object at {where}, got {type(v).__name__}")
    return v


def _expect_list(v: Any, where: str) -> list[Any]:
    if not isinstance(v, list):
        raise UserError(f"Expected array at {where}, got {type(v).__name__}")
    return v


def _expect_str(v: Any, where: str) -> str:
    if not isinstance(v, str) or v.strip() == "":
        raise UserError(f"Expected non-empty string at {where}")
    return v.strip()


def _expect_int(v: Any, where: str) -> int:
    if isinstance(v, bool) or not isinstance(v, int):
        raise UserError(f"Expected integer at {where}")
    return v


def _validate_uuid(u: str) -> None:
    try:
        uuid_lib.UUID(u)
    except Exception:
        raise UserError(f"Invalid UUID: {u}")


def _validate_short_id(sid: str) -> None:
    if not _HEX_RE.match(sid):
        raise UserError(f"shortId must be hex, got: {sid}")
    if len(sid) % 2 != 0:
        raise UserError(f"shortId must have even length, got len={len(sid)} ({sid})")


def _validate_private_key(pk: str) -> None:
    if not _B64URL_RE.match(pk):
        raise UserError(f"privateKey has unexpected format: {pk}")


def _select_inbound(cfg: dict[str, Any], inbound_index: Optional[int]) -> RealityInbound:
    inbounds = _expect_list(cfg.get("inbounds"), "inbounds")
    if not inbounds:
        raise UserError("No inbounds found in config")

    def parse_one(idx: int, inbound_any: Any) -> RealityInbound:
        ib = _expect_dict(inbound_any, f"inbounds[{idx}]")
        protocol = ib.get("protocol")
        if protocol != "vless":
            raise UserError(f"inbounds[{idx}] protocol is not vless: {protocol!r}")

        port = _expect_int(ib.get("port"), f"inbounds[{idx}].port")
        if not (1 <= port <= 65535):
            raise UserError(f"inbounds[{idx}].port out of range: {port}")

        settings = _expect_dict(ib.get("settings"), f"inbounds[{idx}].settings")
        clients = _expect_list(settings.get("clients"), f"inbounds[{idx}].settings.clients")
        if not clients:
            raise UserError(f"inbounds[{idx}].settings.clients is empty")
        c0 = _expect_dict(clients[0], f"inbounds[{idx}].settings.clients[0]")
        uuid = _expect_str(c0.get("id"), f"inbounds[{idx}].settings.clients[0].id")
        flow = c0.get("flow")
        if flow is not None:
            flow = _expect_str(flow, f"inbounds[{idx}].settings.clients[0].flow")

        stream = _expect_dict(ib.get("streamSettings"), f"inbounds[{idx}].streamSettings")
        network = _expect_str(stream.get("network"), f"inbounds[{idx}].streamSettings.network")
        security = _expect_str(stream.get("security"), f"inbounds[{idx}].streamSettings.security")
        if security != "reality":
            raise UserError(f"inbounds[{idx}] streamSettings.security is not reality: {security!r}")

        reality = _expect_dict(stream.get("realitySettings"), f"inbounds[{idx}].streamSettings.realitySettings")
        server_names = _expect_list(reality.get("serverNames"), f"inbounds[{idx}].streamSettings.realitySettings.serverNames")
        if not server_names:
            raise UserError(f"inbounds[{idx}].streamSettings.realitySettings.serverNames is empty")
        sni = _expect_str(server_names[0], f"inbounds[{idx}].streamSettings.realitySettings.serverNames[0]")

        short_ids = _expect_list(reality.get("shortIds"), f"inbounds[{idx}].streamSettings.realitySettings.shortIds")
        if not short_ids:
            raise UserError(f"inbounds[{idx}].streamSettings.realitySettings.shortIds is empty")
        short_id = _expect_str(short_ids[0], f"inbounds[{idx}].streamSettings.realitySettings.shortIds[0]")

        private_key = _expect_str(reality.get("privateKey"), f"inbounds[{idx}].streamSettings.realitySettings.privateKey")

        _validate_uuid(uuid)
        _validate_short_id(short_id)
        _validate_private_key(private_key)

        return RealityInbound(
            uuid=uuid,
            flow=flow,
            port=port,
            network=network,
            sni=sni,
            short_id=short_id.lower(),
            private_key=private_key,
        )

    if inbound_index is not None:
        if inbound_index < 0 or inbound_index >= len(inbounds):
            raise UserError(f"--inbound-index {inbound_index} is out of range (0..{len(inbounds)-1})")
        return parse_one(inbound_index, inbounds[inbound_index])

    last_err: Optional[Exception] = None
    for idx, ib in enumerate(inbounds):
        try:
            return parse_one(idx, ib)
        except Exception as e:
            last_err = e
            continue
    raise UserError(f"No matching inbound found (need protocol=vless + security=reality). Last error: {last_err}")


def compute_public_key_from_private(private_key: str) -> str:
    xray = os.environ.get("XRAY_BIN", "xray")
    try:
        proc = subprocess.run(
            [xray, "x25519", "-i", private_key],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except FileNotFoundError:
        raise UserError(
            "xray binary not found in PATH. Install xray or set XRAY_BIN to the xray executable path.\n"
            "Example: export XRAY_BIN=/usr/local/bin/xray"
        )

    out = (proc.stdout or "").strip()
    if proc.returncode != 0:
        raise UserError(
            f"xray x25519 -i failed (exit {proc.returncode}). Output:\n{out}\n\n"
            "Hint: ensure privateKey is correct and xray is installed."
        )

    # Xray 25.x prints "Password:" where older versions printed "PublicKey:"
    m = re.search(r"^(?:Password|PublicKey):\s*(\S+)\s*$", out, flags=re.MULTILINE)
    if not m:
        raise UserError(f"Failed to parse public key from xray output:\n{out}")
    pub = m.group(1).strip()
    if not _B64URL_RE.match(pub):
        raise UserError(f"Parsed publicKey has unexpected format: {pub}")
    return pub


def build_vless_link(server: str, name: str, fp: str, inbound: RealityInbound, public_key: str) -> str:
    params: dict[str, str] = {
        "type": inbound.network,
        "security": "reality",
        "sni": inbound.sni,
        "fp": fp,
        "pbk": public_key,
        "sid": inbound.short_id,
    }
    if inbound.flow:
        params["flow"] = inbound.flow

    query = urlencode(params, quote_via=quote)
    frag = quote(name, safe="")
    return f"vless://{inbound.uuid}@{server}:{inbound.port}?{query}#{frag}"


def qr_png(link: str, out_path: Path) -> None:
    try:
        import qrcode  # type: ignore
    except Exception:
        raise UserError("Python dependency 'qrcode' is missing. Install: python3 -m pip install 'qrcode[pil]'")

    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2)
    qr.add_data(link)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    img.save(out_path)


def qr_ansi(link: str) -> None:
    try:
        import qrcode  # type: ignore
    except Exception:
        raise UserError("Python dependency 'qrcode' is missing (needed for --print-qr). Install: python3 -m pip install 'qrcode[pil]'")

    qr = qrcode.QRCode(border=1)
    qr.add_data(link)
    qr.make(fit=True)
    if hasattr(qr, "print_ascii"):
        qr.print_ascii(invert=True)  # type: ignore[attr-defined]
        return

    m = qr.get_matrix()
    black = "\x1b[40m  \x1b[0m"
    white = "\x1b[47m  \x1b[0m"
    for row in m:
        print("".join(black if cell else white for cell in row))


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="xray_reality_qr", description="Generate VLESS Reality share link + QR from Xray config JSON")
    p.add_argument("config", type=Path, help="Path to Xray server config JSON (Xray core config structure)")
    p.add_argument("--server", required=True, help="Public server host/IP used in the share link")
    p.add_argument("--name", default="reality-443", help='Link name used in URL fragment (#NAME). Default: "reality-443"')
    p.add_argument("--fp", default="chrome", help='Fingerprint (fp=). Default: "chrome"')
    p.add_argument("--out", default="vless.png", type=Path, help='Output PNG filename. Default: "vless.png"')
    p.add_argument("--print-link", action="store_true", help="Print generated vless:// link to stdout")
    p.add_argument("--print-qr", action="store_true", help="Print QR code to terminal (ANSI/ASCII)")
    p.add_argument("--inbound-index", type=int, default=None, help="Select a specific inbound index, otherwise auto-detect first matching inbound")
    p.add_argument("--dry-run", action="store_true", help="Only print extracted fields and computed publicKey, do not generate QR PNG")
    args = p.parse_args(argv)

    cfg_any = _load_json(args.config)
    cfg = _expect_dict(cfg_any, "root")
    inbound = _select_inbound(cfg, args.inbound_index)
    public_key = compute_public_key_from_private(inbound.private_key)

    link = build_vless_link(args.server, args.name, args.fp, inbound, public_key)
    if args.dry_run:
        print(link)
        return 0

    qr_png(link, args.out)
    if args.print_link:
        print(link)
    if args.print_qr:
        qr_ansi(link)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except UserError as e:
        _die(str(e), code=2)


