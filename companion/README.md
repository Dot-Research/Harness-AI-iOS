# Harness Companion

A small computer worker for Harness. Python 3.11+ and OpenSSL are required; the HTTPS server, storage, authentication and tools use only the Python standard library. It does not require a model provider, cloud account or reusable password in a QR code.

## Start on your computer

```sh
cd companion
python3 -m venv .venv
.venv/bin/python -m pip install ".[qr]"
.venv/bin/harness pair --root "$HOME/Projects" --host 192.168.1.20
```

`--host` is the computer's LAN IP or DNS name, reachable by the phone. The default bind address is all IPv4 interfaces. Keep the node on a trusted LAN; allow its TCP port 8443 in the computer firewall as needed.

On the phone open **Me → Devices → Add Computer**, then scan the terminal QR. With no optional QR dependency, run `python3 -m harness_companion pair --root <folder> --host <LAN-IP>` from this directory and import the printed QR JSON on the phone.

The phone must pin the QR's SHA-256 certificate fingerprint **before** transmitting the ephemeral pairing token. HTTPS is always enabled; unverified plain HTTP is unavailable. The pairing token is cryptographically random, single use and expires after five minutes. A new CLI invocation generates a fresh pairing invitation; existing paired devices retain their authorization while the node is running. Treat the QR and terminal JSON as private until the invitation expires.

Only `readFile` is granted by default, within the root explicitly selected on the computer. Enable capabilities independently, for example:

```sh
harness pair --root "$HOME/Projects" --host 192.168.1.20 \
  --grant readFile --grant writeFile
```

Add `--grant execute` only when you want the phone to run commands as your computer user. Commands receive an argument array with `shell=False`, a working directory inside the selected root, a maximum 60-second timeout and bounded captured output. **An execute grant is computer-user code execution; the selected filesystem root is not a process sandbox.** Invoked programs can access whatever that operating-system user can access. The phone's deterministic Permission Kernel must separately approve actions.

Stop the server with Ctrl-C. To revoke a device, stop the node and run:

```sh
harness revoke --device <deviceId-from-pairing>
```

Removing a device on the phone removes its local Keychain token only. Revoke it on the companion too if its reusable token could have been copied. Printing a new pairing invitation does not revoke existing devices.

The state directory defaults to `~/.local/share/harness`; override with `--state-dir`. It contains a TLS certificate, private key and `devices.json`. Device records store a SHA-256 hash of the bearer token, never its reusable value. On Unix, files have mode 0600 and the directory 0700. Back up the private state securely, keep it out of version control, and run only one node using a given state directory. Root changes invalidate old credentials for the new root; reducing computer grants immediately reduces existing devices' effective permissions.

The generated certificate's subject alternative name matches `--host`. Startup validates the saved certificate's hostname and expiration. If the computer's advertised address changes or the certificate expires, select a new `--state-dir` and pair again; the phone must retain hostname/date verification as well as the scanned certificate pin.

macOS/Linux path access uses directory descriptors with `O_NOFOLLOW` to prevent symlink resolution races. File tools reject traversal, absolute paths, symlinks, hard links and non-regular files. The node's private state is excluded even if located under the selected root.

Windows pairing/command execution is experimental. Use `.venv\Scripts\python.exe` and `.venv\Scripts\harness.exe`, explicitly add `--grant execute`, and install OpenSSL. Windows filesystem grants fail closed at startup until native secure relative handles are implemented; default `readFile` startup is therefore unavailable. State directories and credential files receive protected owner-only Windows DACLs through noninteractive PowerShell 5+; failure to establish them blocks startup. Native Windows ACL/process behavior and macOS execution are not tested by the Linux integration suite.

## Protocol v1

QR payload:

```json
{
  "version": 1,
  "url": "https://192.168.1.20:8443",
  "token": "ephemeral-single-use-token",
  "fingerprint": "lowercase-sha256-of-certificate-DER",
  "expiresAt": "2026-10-07T00:05:00Z"
}
```

The certificate fingerprint hashes the entire DER-encoded X.509 certificate. Store the pin and the paired token using Keychain on iOS. A mismatching certificate, expired invitation, unsupported version or insecure URL must fail closed. The generated certificate is self-signed: validate it against the scanned pin rather than disabling TLS verification globally.

`POST /pair` accepts a JSON object:

```json
{"token":"ephemeral-token","deviceName":"My iPhone","capabilities":["readFile"]}
```

`capabilities` is optional; omission selects the computer's granted set. Selecting any capability not enabled by `--grant` fails. Success returns:

```json
{
  "nodeId": "uuid",
  "deviceId": "uuid",
  "name": "Harness Companion",
  "token": "new-persistent-bearer-token",
  "capabilities": ["readFile"],
  "root": "/selected/folder"
}
```

The reusable bearer is returned only from successful TLS pairing. All tool endpoints require `Authorization: Bearer <token>` and `Content-Type: application/json`:

| Route | Request | Success response |
| --- | --- | --- |
| `GET /health` | none, public | `{"status":"ok","protocol":1}` |
| `POST /tools/readFile` | `{"path":"folder/file.txt"}` | `{"path":"folder/file.txt","content":"text","encoding":"utf-8"}` |
| `POST /tools/writeFile` | `{"path":"file.txt","content":"text"}` | `{"path":"file.txt","writtenBytes":4}` |
| `POST /tools/execute` | `{"command":["python3","-c","print('hello')"],"timeout":30}` | `{"exitCode":0,"stdout":"hello\n","stderr":"","truncated":false,"timedOut":false}` |

Paths use slash-separated relative components. Parent traversal, empty components and backslashes are rejected. Parent directories must already exist. File operations support UTF-8 text up to 1 MiB; requests are bounded. stdout and stderr are each capped at 64 KiB; excess output is consumed and discarded. HTTP workers, TLS handshake duration and request-read duration are bounded. Errors are `{"error":{"code":"...","message":"..."}}` with a 4xx/5xx status and no credentials or private exception detail. The companion does not log request bodies or command output.

## Validate

```sh
cd companion
python3 -m unittest discover -s tests -v
```

The suite opens actual HTTPS sockets with a trusted test certificate, pairs real clients, manipulates temporary files and runs bounded processes. It covers certificate verification and fingerprint matching, single-use/concurrent/expired pairing, token hashing and permissions, persistence/revocation, independent grants, UTF-8 read/write, traversal, symlink/hard-link/FIFO/private-state rejection, shell interpolation prevention and timeout/output limits.
