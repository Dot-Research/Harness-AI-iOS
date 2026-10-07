"""Small stdlib node. A model never participates in its authorization decisions."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import signal
import ssl
import stat
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

CAPABILITIES = frozenset({"readFile", "writeFile", "execute"})
MAX_BODY = 1024 * 1024 + 4096
MAX_FILE = 1024 * 1024
MAX_OUTPUT = 64 * 1024


class NodeError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def _secure_permissions(path: Path, directory: bool = False) -> None:
    """Unix modes or a protected Windows DACL restricted to the current user."""
    if os.name != "nt":
        os.chmod(path, 0o700 if directory else 0o600)
        return
    # Pass the path as data via a dedicated variable, never as PowerShell code.
    script = """
$ErrorActionPreference = 'Stop'
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
if ($env:HARNESS_ACL_DIRECTORY -eq '1') {
  $acl = [System.Security.AccessControl.DirectorySecurity]::new()
  $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
} else {
  $acl = [System.Security.AccessControl.FileSecurity]::new()
  $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow')
}
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $env:HARNESS_ACL_PATH -AclObject $acl
"""
    environment = os.environ.copy()
    environment["HARNESS_ACL_PATH"] = str(path.resolve(strict=True))
    environment["HARNESS_ACL_DIRECTORY"] = "1" if directory else "0"
    try:
        subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                       env=environment, check=True, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("Could not protect Windows credential storage; private user ACL is required") from error


def _private_write(path: Path, data: bytes) -> None:
    """Replace a state file atomically without leaving a world-readable window."""
    fd, temporary = tempfile.mkstemp(prefix=".harness-", dir=path.parent)
    try:
        _secure_permissions(Path(temporary))
        stream = os.fdopen(fd, "wb")
        fd = -1  # The stream owns and closes the descriptor from this point.
        with stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(temporary):
            os.unlink(temporary)


def certificate_fingerprint(certificate: Path) -> str:
    der = ssl.PEM_cert_to_DER_cert(certificate.read_text(encoding="ascii"))
    return hashlib.sha256(der).hexdigest()


def ensure_certificate(state_dir: Path, hostname: str) -> tuple[Path, Path]:
    """Generate an OpenSSL self-signed certificate for explicit iPhone pinning."""
    import ipaddress
    try:
        ipaddress.ip_address(hostname)
        san, check_flag = "IP:" + hostname, "-verify_ip"
    except ValueError:
        if not hostname or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-" for c in hostname):
            raise ValueError("Host must be an IP address or DNS name")
        san, check_flag = "DNS:" + hostname, "-verify_hostname"
    certificate, key = state_dir / "certificate.pem", state_dir / "private-key.pem"
    for path in (certificate, key):
        if path.is_symlink():
            raise ValueError("TLS state files cannot be symbolic links")
    if certificate.exists() != key.exists():
        raise ValueError("Incomplete TLS state; restore both certificate and key")
    if not certificate.exists():
        # OpenSSL writes into files already created with private permissions.
        try:
            for path in (certificate, key):
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                os.close(fd)
                _secure_permissions(path)
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
                 "-days", "365", "-subj", "/CN=Harness Companion", "-addext", "subjectAltName=" + san,
                 "-keyout", str(key), "-out", str(certificate)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60,
            )
        except BaseException:
            certificate.unlink(missing_ok=True)
            key.unlink(missing_ok=True)
            raise
    result = subprocess.run(["openssl", "verify", "-CAfile", str(certificate),
                             check_flag, hostname, str(certificate)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    if result.returncode:
        raise ValueError("Saved certificate is expired or does not match --host; use a new --state-dir and re-pair")
    _secure_permissions(key)
    return certificate, key


class Node:
    def __init__(self, root: Path, state_dir: Path, grants: set[str] | None = None,
                 pairing_seconds: int = 300, clock=time.time):
        # A root is always a deliberate CLI argument, never the whole computer by default.
        self.root = root.resolve(strict=True)
        if not self.root.is_dir():
            raise ValueError("The selected filesystem root must be a directory")
        self.grants = frozenset({"readFile"} if grants is None else grants)
        if not self.grants <= CAPABILITIES:
            raise ValueError("Unknown capability")
        if (os.name != "posix" or not hasattr(os, "O_NOFOLLOW")) and self.grants & {"readFile", "writeFile"}:
            raise ValueError("Filesystem grants require secure macOS/Linux path handles; Windows supports explicit --grant execute only")
        if not 1 <= pairing_seconds <= 900:
            raise ValueError("Pairing expiry must be between 1 and 900 seconds")
        self.state_dir = state_dir
        if state_dir.is_symlink():
            raise ValueError("State directory cannot be a symbolic link")
        state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        _secure_permissions(state_dir, directory=True)
        self.state_dir = state_dir.resolve(strict=True)
        self.state_file = state_dir / "devices.json"
        if self.state_file.is_symlink():
            raise ValueError("Device state cannot be a symbolic link")
        self.clock = clock
        self.lock = threading.RLock()
        self._processes: set[subprocess.Popen] = set()
        self._closing = False
        self.pairing_token = secrets.token_urlsafe(32)
        self.expires_at = clock() + pairing_seconds
        if self.state_file.exists():
            _secure_permissions(self.state_file)
            self.state = json.loads(self.state_file.read_text(encoding="utf-8"))
        else:
            self.state = {"nodeId": str(uuid.uuid4()), "devices": []}
            self._save()

    def _save(self):
        _private_write(self.state_file, json.dumps(self.state, indent=2).encode())

    def pairing_payload(self, url: str, fingerprint: str) -> dict:
        return {"version": 1, "url": url, "token": self.pairing_token,
                "fingerprint": fingerprint,
                "expiresAt": datetime.fromtimestamp(self.expires_at, timezone.utc).isoformat().replace("+00:00", "Z")}

    def pair(self, body: dict) -> dict:
        token = body.get("token")
        if not isinstance(token, str) or len(token) > 256:
            raise NodeError("invalid_pairing", "Pairing token is invalid or expired", 401)
        requested = body.get("capabilities", sorted(self.grants))
        if not isinstance(requested, list) or not all(isinstance(x, str) for x in requested):
            raise NodeError("invalid_request", "Capabilities must be an array of names")
        requested_set = set(requested)
        if not requested_set <= self.grants:
            raise NodeError("capability_denied", "A requested capability was not granted on this computer", 403)
        name = body.get("deviceName", "iPhone")
        if not isinstance(name, str) or not 1 <= len(name) <= 120:
            raise NodeError("invalid_request", "Device name must contain 1 to 120 characters")
        with self.lock:
            if (self.pairing_token is None or self.clock() >= self.expires_at or
                    not hmac.compare_digest(token.encode("utf-8"), self.pairing_token.encode("ascii"))):
                raise NodeError("invalid_pairing", "Pairing token is invalid or expired", 401)
            bearer = secrets.token_urlsafe(32)
            record = {"id": str(uuid.uuid4()), "name": name,
                      "tokenHash": hashlib.sha256(bearer.encode()).hexdigest(),
                      "capabilities": sorted(requested_set), "root": str(self.root)}
            self.state["devices"].append(record)
            try:
                self._save()
            except BaseException:
                self.state["devices"].remove(record)
                raise
            self.pairing_token = None  # Consume only after durable storage succeeds.
            return {"nodeId": self.state["nodeId"], "deviceId": record["id"],
                    "name": "Harness Companion", "token": bearer,
                    "capabilities": record["capabilities"], "root": str(self.root)}

    def authorize(self, authorization: str | None, capability: str) -> dict:
        if not authorization or not authorization.startswith("Bearer ") or len(authorization) > 512:
            raise NodeError("unauthorized", "A paired device token is required", 401)
        digest = hashlib.sha256(authorization[7:].encode()).hexdigest()
        matched = None
        with self.lock:
            for device in self.state["devices"]:
                if hmac.compare_digest(digest, device["tokenHash"]):
                    matched = device
            if matched is None or matched["root"] != str(self.root):
                raise NodeError("unauthorized", "A paired device token is required", 401)
            if capability not in self.grants or capability not in matched["capabilities"]:
                raise NodeError("capability_denied", "This device has no grant for this capability", 403)
            return matched.copy()

    def revoke(self, device_id: str) -> bool:
        with self.lock:
            before = len(self.state["devices"])
            self.state["devices"] = [x for x in self.state["devices"] if x["id"] != device_id]
            self._save()
            return len(self.state["devices"]) != before

    def _components(self, path: Any) -> list[str]:
        if not isinstance(path, str) or not path or len(path) > 4096:
            raise NodeError("invalid_path", "Use a relative path under the selected root")
        parts = path.split("/")
        if path.startswith("/") or "\\" in path or ":" in path or "\0" in path or any(x in {"", ".", ".."} for x in parts):
            raise NodeError("invalid_path", "Use a relative path without traversal")
        if self.root.joinpath(*parts).is_relative_to(self.state_dir):
            raise NodeError("invalid_path", "Companion private state cannot be shared", 403)
        return parts

    def _open_file(self, path: Any, write: bool = False) -> int:
        parts = self._components(path)
        flags = (os.O_WRONLY | os.O_CREAT) if write else os.O_RDONLY
        if os.name == "posix" and hasattr(os, "O_NOFOLLOW"):
            # Walk descriptors, rejecting all symlinks and avoiding resolve/open races.
            directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                for part in parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    os.close(directory)
                    directory = child
                fd = os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
            except OSError as error:
                raise NodeError("invalid_path", "File is unavailable or path is unsafe", 403) from error
            finally:
                os.close(directory)
        else:
            raise NodeError("platform_unsupported", "Filesystem tools require secure macOS/Linux path handles", 403)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            os.close(fd)
            raise NodeError("invalid_path", "Only regular files without hard links are available", 403)
        return fd

    def read_file(self, body: dict) -> dict:
        fd = self._open_file(body.get("path"))
        with os.fdopen(fd, "rb") as stream:
            data = stream.read(MAX_FILE + 1)
        if len(data) > MAX_FILE:
            raise NodeError("file_too_large", "File exceeds the 1 MiB limit", 413)
        try:
            content = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise NodeError("invalid_encoding", "Only UTF-8 text files are supported") from error
        return {"path": body["path"], "content": content, "encoding": "utf-8"}

    def write_file(self, body: dict) -> dict:
        content = body.get("content")
        if not isinstance(content, str):
            raise NodeError("invalid_request", "Content must be UTF-8 text")
        data = content.encode("utf-8")
        if len(data) > MAX_FILE:
            raise NodeError("file_too_large", "File exceeds the 1 MiB limit", 413)
        fd = self._open_file(body.get("path"), write=True)
        with os.fdopen(fd, "wb") as stream:
            # Truncate after validating the descriptor is a regular file.
            stream.truncate(0)
            stream.write(data)
        return {"path": body["path"], "writtenBytes": len(data)}

    def execute(self, body: dict) -> dict:
        command = body.get("command")
        timeout = body.get("timeout", 30)
        if (not isinstance(command, list) or not 1 <= len(command) <= 128 or
                not all(isinstance(x, str) and "\0" not in x and len(x) <= 8192 for x in command) or
                not command[0] or isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= 60):
            raise NodeError("invalid_request", "Command must be an argument array; timeout must be between 0 and 60 seconds")
        try:
            with self.lock:
                if self._closing:
                    raise NodeError("node_stopping", "The companion is stopping", 503)
                process = subprocess.Popen(command, cwd=self.root, shell=False,
                                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           start_new_session=(os.name == "posix"))
                self._processes.add(process)
        except OSError as error:
            raise NodeError("command_unavailable", "Command could not be started", 422) from error
        outputs = [bytearray(), bytearray()]
        truncated = [False, False]

        def drain(stream, index):
            with stream:
                while chunk := stream.read(8192):
                    space = MAX_OUTPUT - len(outputs[index])
                    outputs[index].extend(chunk[:space])
                    if len(chunk) > space:
                        truncated[index] = True

        workers = [threading.Thread(target=drain, args=(stream, i), daemon=True)
                   for i, stream in enumerate((process.stdout, process.stderr))]
        for worker in workers:
            worker.start()
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            # Descendants may retain pipes after their parent exits. End the process group.
            self._terminate(process)
            try:
                process.wait(timeout=3)
            finally:
                with self.lock:
                    self._processes.discard(process)
        for worker in workers:
            worker.join(timeout=3)
        return {"exitCode": process.returncode, "stdout": outputs[0].decode("utf-8", errors="replace"),
                "stderr": outputs[1].decode("utf-8", errors="replace"),
                "truncated": any(truncated), "timedOut": timed_out}

    @staticmethod
    def _terminate(process):
        if os.name == "posix":
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        elif process.poll() is None:
            try:
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                process.kill()

    def close(self):
        with self.lock:
            self._closing = True
            processes = list(self._processes)
        for process in processes:
            self._terminate(process)


class NodeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, node: Node, certificate: Path, key: Path):
        self.node = node
        self._slots = threading.BoundedSemaphore(32)
        super().__init__(address, Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certificate, key)
        self.socket = context.wrap_socket(self.socket, server_side=True, do_handshake_on_connect=False)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(10)
            request.do_handshake()
            super().process_request_thread(request, client_address)
        except (ssl.SSLError, OSError):
            request.close()
        finally:
            self._slots.release()

    def handle_error(self, request, client_address):
        # Never print request bodies, credentials or tool output in HTTP errors.
        pass

    def server_close(self):
        self.node.close()
        super().server_close()


class Handler(BaseHTTPRequestHandler):
    server_version = "Harness"
    sys_version = ""

    def log_message(self, *_args):
        pass  # Local actions belong in the phone's audit trail, not credential-bearing server logs.

    def _respond(self, status: int, value: dict):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok", "protocol": 1})
        else:
            self._respond(404, {"error": {"code": "not_found", "message": "Unknown endpoint"}})

    def do_POST(self):
        try:
            if self.headers.get("Transfer-Encoding") is not None:
                raise NodeError("invalid_request", "Transfer-Encoding is not supported")
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError as error:
                raise NodeError("invalid_request", "Content-Length is required") from error
            if not 0 < length <= MAX_BODY:
                raise NodeError("request_too_large", "Request must contain bounded JSON", 413)
            content_type = self.headers.get("Content-Type", "").split(";")[0].strip()
            if content_type != "application/json":
                raise NodeError("invalid_request", "Content-Type must be application/json", 415)
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise NodeError("invalid_request", "Incomplete body")
            try:
                body = json.loads(raw)
            except (ValueError, UnicodeDecodeError) as error:
                raise NodeError("invalid_request", "Body must contain valid JSON") from error
            if not isinstance(body, dict):
                raise NodeError("invalid_request", "Body must be a JSON object")
            node = self.server.node
            if self.path == "/pair":
                self._respond(200, node.pair(body))
            elif self.path in {"/tools/readFile", "/tools/writeFile", "/tools/execute"}:
                capability = self.path.rsplit("/", 1)[1]
                node.authorize(self.headers.get("Authorization"), capability)
                function = {"readFile": node.read_file, "writeFile": node.write_file, "execute": node.execute}[capability]
                self._respond(200, function(body))
            else:
                raise NodeError("not_found", "Unknown endpoint", 404)
        except NodeError as error:
            self._respond(error.status, {"error": {"code": error.code, "message": error.message}})
        except (OSError, ValueError, OverflowError):
            self._respond(500, {"error": {"code": "node_error", "message": "The requested operation could not be completed"}})
