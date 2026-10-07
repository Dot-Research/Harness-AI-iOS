"""Run `harness pair` or `python -m harness_companion pair`."""

import argparse
import json
from pathlib import Path
import sys
import subprocess
from urllib.parse import urlsplit

from .node import CAPABILITIES, Node, NodeHTTPServer, certificate_fingerprint, ensure_certificate


def main(argv=None):
    parser = argparse.ArgumentParser(description="Harness computer node: explicit grants and TLS-pinned pairing")
    commands = parser.add_subparsers(dest="action", required=True)
    pair = commands.add_parser("pair", help="Start HTTPS node and display a single-use pairing QR")
    pair.add_argument("--root", type=Path, required=True, help="Explicit filesystem root shared with the phone")
    pair.add_argument("--host", required=True, help="Computer's LAN IP or DNS name reachable by the phone")
    pair.add_argument("--bind", default="0.0.0.0", help="Listening address (default: all IPv4 interfaces)")
    pair.add_argument("--port", type=int, default=8443)
    pair.add_argument("--grant", choices=sorted(CAPABILITIES), action="append",
                      help="Repeat for each capability; default is readFile only")
    pair.add_argument("--expires-in", type=int, default=300, help="QR validity in seconds (1–900; default 300)")
    pair.add_argument("--state-dir", type=Path, default=Path.home() / ".local" / "share" / "harness")
    pair.add_argument("--no-qr", action="store_true", help="Print QR JSON only")
    revoke = commands.add_parser("revoke", help="Revoke a paired device while the node is stopped")
    revoke.add_argument("--device", required=True, help="Device ID returned by pairing")
    revoke.add_argument("--state-dir", type=Path, default=Path.home() / ".local" / "share" / "harness")
    args = parser.parse_args(argv)
    try:
        if args.action == "revoke":
            from .node import _private_write, _secure_permissions
            path = args.state_dir / "devices.json"
            if path.is_symlink():
                raise ValueError("Device state cannot be a symbolic link")
            _secure_permissions(args.state_dir, directory=True)
            _secure_permissions(path)
            state = json.loads(path.read_text(encoding="utf-8"))
            before = len(state["devices"])
            state["devices"] = [x for x in state["devices"] if x["id"] != args.device]
            _private_write(path, json.dumps(state, indent=2).encode())
            print("Device revoked." if len(state["devices"]) != before else "Device ID was not found.")
            return
        if not 0 <= args.port <= 65535:
            raise ValueError("Port must be between 0 and 65535")
        if any(x in args.host for x in "/@?#"):
            raise ValueError("Host must be an IP address or DNS name, without a URL scheme or path")
        node = Node(args.root, args.state_dir, set(args.grant) if args.grant else None,
                    pairing_seconds=args.expires_in)
        certificate, key = ensure_certificate(args.state_dir, args.host)
        with NodeHTTPServer((args.bind, args.port), node, certificate, key) as server:
            hostname = f"[{args.host}]" if ":" in args.host else args.host
            url = f"https://{hostname}:{server.server_port}"
            if urlsplit(url).hostname != args.host:
                raise ValueError("Invalid advertised host")
            payload = json.dumps(node.pairing_payload(url, certificate_fingerprint(certificate)), separators=(",", ":"))
            print("Harness Companion — scan in Me → Devices → Add Computer", flush=True)
            print("Capabilities: " + ", ".join(sorted(node.grants)), flush=True)
            if "execute" in node.grants:
                print("execute grants code execution as this computer user; filesystem root limits do not sandbox commands.", flush=True)
            print("Pairing JSON (single use; treat as private until it expires):", flush=True)
            print(payload, flush=True)
            if not args.no_qr:
                try:
                    import segno
                    segno.make(payload, micro=False, error="m").terminal(compact=True)
                except ImportError:
                    print('QR rendering is optional. Install: pip install "harness-companion[qr]"', flush=True)
            print("Listening over TLS. Keep this process running; Ctrl-C stops the node.", flush=True)
            try:
                server.serve_forever(poll_interval=0.25)
            except KeyboardInterrupt:
                pass
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Harness could not start: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
