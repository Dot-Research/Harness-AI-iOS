"""Integration tests use actual TLS sockets, certificates, files and processes."""

import hashlib
import http.client
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from harness_companion.node import MAX_OUTPUT, Node, NodeError, NodeHTTPServer, certificate_fingerprint, ensure_certificate


class TLSNodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certs = tempfile.TemporaryDirectory()
        cls.certificate, cls.key = ensure_certificate(Path(cls.certs.name), "127.0.0.1")
        cls.context = ssl.create_default_context(cafile=str(cls.certificate))

    @classmethod
    def tearDownClass(cls):
        cls.certs.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.base = Path(self.directory.name)
        self.root = self.base / "shared"
        self.root.mkdir()
        self.state_dir = self.base / "private"
        self.node = Node(self.root, self.state_dir, {"readFile", "writeFile", "execute"})
        self.server = NodeHTTPServer(("127.0.0.1", 0), self.node, self.certificate, self.key)
        self.worker = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.worker.start()
        self.bearer = None

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()
        self.directory.cleanup()

    def request(self, path, body=None, bearer=None, context=None, content_type="application/json"):
        conn = http.client.HTTPSConnection("127.0.0.1", self.server.server_port, context=context or self.context, timeout=5)
        headers = {"Content-Type": content_type}
        if bearer is not None:
            headers["Authorization"] = "Bearer " + bearer
        try:
            conn.request("GET" if body is None else "POST", path,
                         body=None if body is None else json.dumps(body), headers=headers)
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def pair(self, capabilities=None):
        body = {"token": self.node.pairing_token, "deviceName": "Test iPhone"}
        if capabilities is not None:
            body["capabilities"] = capabilities
        status, value = self.request("/pair", body)
        self.assertEqual(status, 200, value)
        self.bearer = value["token"]
        return value

    def test_public_health_reveals_no_identity_credentials_or_root(self):
        status, value = self.request("/health")
        self.assertEqual(status, 200)
        self.assertEqual(value, {"status": "ok", "protocol": 1})

    def test_tls_certificate_validation_is_required(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.request("/health", context=ssl.create_default_context())

    def test_fingerprint_matches_actual_tls_certificate(self):
        conn = http.client.HTTPSConnection("127.0.0.1", self.server.server_port, context=self.context)
        try:
            conn.connect()
            actual = hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
            self.assertEqual(actual, certificate_fingerprint(self.certificate))
            payload = self.node.pairing_payload("https://127.0.0.1:8443", actual)
            self.assertEqual(payload["fingerprint"], actual)
            self.assertEqual(payload["version"], 1)
            self.assertTrue(payload["expiresAt"].endswith("Z"))
        finally:
            conn.close()

    def test_saved_certificate_cannot_be_reused_for_a_different_advertised_host(self):
        with self.assertRaises(ValueError):
            ensure_certificate(Path(self.certs.name), "127.0.0.2")

    def test_pairing_is_single_use_and_stores_only_hash_with_private_permissions(self):
        token = self.node.pairing_token
        value = self.pair()
        self.assertNotEqual(token, self.bearer)
        status, _ = self.request("/pair", {"token": token})
        self.assertEqual(status, 401)
        saved = self.node.state_file.read_text()
        self.assertNotIn(token, saved)
        self.assertNotIn(self.bearer, saved)
        self.assertIn(hashlib.sha256(self.bearer.encode()).hexdigest(), saved)
        self.assertEqual(value["capabilities"], ["execute", "readFile", "writeFile"])
        if os.name == "posix":
            self.assertEqual(self.node.state_file.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.state_dir.stat().st_mode & 0o777, 0o700)
            self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)

    def test_pairing_fails_for_wrong_expired_and_unicode_tokens(self):
        for token in ("wrong", "🔑"):
            status, _ = self.request("/pair", {"token": token})
            self.assertEqual(status, 401)
        self.node.expires_at = time.time() - 1
        status, _ = self.request("/pair", {"token": self.node.pairing_token})
        self.assertEqual(status, 401)

    def test_concurrent_pairing_succeeds_exactly_once(self):
        token = self.node.pairing_token
        statuses = []
        workers = [threading.Thread(target=lambda: statuses.append(self.request("/pair", {"token": token})[0])) for _ in range(8)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join()
        self.assertEqual(statuses.count(200), 1)
        self.assertEqual(statuses.count(401), 7)
        self.assertEqual(len(self.node.state["devices"]), 1)

    def test_tools_require_authentication(self):
        (self.root / "hello.txt").write_text("secret")
        for token in (None, "invalid"):
            status, _ = self.request("/tools/readFile", {"path": "hello.txt"}, bearer=token)
            self.assertEqual(status, 401)

    def test_explicit_pairing_subset_cannot_gain_other_capabilities(self):
        self.pair(["readFile"])
        for route, body in (("writeFile", {"path": "new.txt", "content": "no"}),
                            ("execute", {"command": [sys.executable, "-c", "print('no')"]})):
            status, value = self.request("/tools/" + route, body, self.bearer)
            self.assertEqual(status, 403)
            self.assertEqual(value["error"]["code"], "capability_denied")
        self.assertFalse((self.root / "new.txt").exists())

    def test_default_node_grants_only_read_file(self):
        default = Node(self.root, self.base / "default-private")
        self.assertEqual(default.grants, {"readFile"})
        with self.assertRaises(NodeError) as error:
            default.pair({"token": default.pairing_token, "capabilities": ["execute"]})
        self.assertEqual(error.exception.status, 403)
        self.assertIsNotNone(default.pairing_token)

    def test_authentication_persists_restart_and_revocation_removes_access(self):
        pair = self.pair(["readFile"])
        restarted = Node(self.root, self.state_dir)
        self.assertEqual(restarted.authorize("Bearer " + self.bearer, "readFile")["id"], pair["deviceId"])
        self.assertTrue(restarted.revoke(pair["deviceId"]))
        with self.assertRaises(NodeError) as error:
            restarted.authorize("Bearer " + self.bearer, "readFile")
        self.assertEqual(error.exception.status, 401)

    def test_changing_root_or_removing_capability_does_not_broaden_prior_grant(self):
        self.pair()
        another = self.base / "another"
        another.mkdir()
        with self.assertRaises(NodeError):
            Node(another, self.state_dir).authorize("Bearer " + self.bearer, "readFile")
        with self.assertRaises(NodeError) as error:
            Node(self.root, self.state_dir).authorize("Bearer " + self.bearer, "execute")
        self.assertEqual(error.exception.status, 403)

    def test_read_and_write_utf8_files_over_https(self):
        self.pair()
        body = {"path": "greeting.txt", "content": "Hello, 世界"}
        status, value = self.request("/tools/writeFile", body, self.bearer)
        self.assertEqual(status, 200, value)
        self.assertEqual(value["writtenBytes"], len(body["content"].encode()))
        status, value = self.request("/tools/readFile", {"path": "greeting.txt"}, self.bearer)
        self.assertEqual(status, 200)
        self.assertEqual(value["content"], body["content"])
        self.assertEqual(value["encoding"], "utf-8")

    def test_traversal_and_absolute_paths_are_denied(self):
        self.pair()
        for path in ("../private/devices.json", "/etc/passwd", "dir/../../x", "dir/../x", "C:\\Windows\\x", "dir\\x", "./x", "dir//x", "x\0"):
            status, value = self.request("/tools/readFile", {"path": path}, self.bearer)
            self.assertEqual(status, 400, (path, value))

    def test_symlink_file_directory_and_hardlink_cannot_escape_root(self):
        self.pair()
        outside = self.base / "outside.txt"
        outside.write_text("outside stays safe")
        (self.root / "link").symlink_to(outside)
        (self.root / "directory-link").symlink_to(self.base, target_is_directory=True)
        os.link(outside, self.root / "hardlink")
        for path in ("link", "directory-link/outside.txt", "hardlink"):
            for route, body in (("readFile", {"path": path}), ("writeFile", {"path": path, "content": "compromised"})):
                status, _ = self.request("/tools/" + route, body, self.bearer)
                self.assertEqual(status, 403, path)
        self.assertEqual(outside.read_text(), "outside stays safe")

    def test_fifo_is_rejected_without_blocking(self):
        if not hasattr(os, "mkfifo"):
            self.skipTest("FIFO files are POSIX only")
        self.pair()
        os.mkfifo(self.root / "pipe")
        status, _ = self.request("/tools/readFile", {"path": "pipe"}, self.bearer)
        self.assertEqual(status, 403)

    def test_private_state_inside_selected_root_is_inaccessible(self):
        node = Node(self.base, self.base / "internal-private")
        with self.assertRaises(NodeError) as error:
            node.read_file({"path": "internal-private/devices.json"})
        self.assertEqual(error.exception.status, 403)

    def test_binary_and_oversize_files_are_rejected(self):
        self.pair()
        (self.root / "binary").write_bytes(b"\xff")
        (self.root / "large").write_bytes(b"x" * (1024 * 1024 + 1))
        status, _ = self.request("/tools/readFile", {"path": "binary"}, self.bearer)
        self.assertEqual(status, 400)
        status, _ = self.request("/tools/readFile", {"path": "large"}, self.bearer)
        self.assertEqual(status, 413)

    def test_execution_uses_argument_array_without_shell_interpolation(self):
        self.pair()
        literal = "$(touch compromised) ; echo injected"
        status, value = self.request("/tools/execute", {"command": [sys.executable, "-c", "import sys; print(sys.argv[1])", literal]}, self.bearer)
        self.assertEqual(status, 200, value)
        self.assertEqual(value["stdout"].strip(), literal)
        self.assertEqual(value["exitCode"], 0)
        self.assertFalse((self.root / "compromised").exists())
        status, _ = self.request("/tools/execute", {"command": "echo forbidden"}, self.bearer)
        self.assertEqual(status, 400)

    def test_execution_timeout_and_output_are_bounded(self):
        self.pair()
        status, value = self.request("/tools/execute", {"command": [sys.executable, "-c", "import time; time.sleep(10)"], "timeout": 0.1}, self.bearer)
        self.assertEqual(status, 200)
        self.assertTrue(value["timedOut"])
        status, value = self.request("/tools/execute", {"command": [sys.executable, "-c", "print('x' * 200000)"]}, self.bearer)
        self.assertEqual(status, 200)
        self.assertTrue(value["truncated"])
        self.assertEqual(len(value["stdout"].encode()), MAX_OUTPUT)

    def test_stopping_node_terminates_running_command(self):
        self.pair()
        values = []
        worker = threading.Thread(target=lambda: values.append(self.request(
            "/tools/execute", {"command": [sys.executable, "-c", "import time; time.sleep(30)"], "timeout": 60}, self.bearer)))
        worker.start()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with self.node.lock:
                running = bool(self.node._processes)
            if running:
                break
            time.sleep(0.01)
        self.assertTrue(running)
        self.node.close()
        worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(values[0][0], 200)
        self.assertNotEqual(values[0][1]["exitCode"], 0)

    def test_http_requires_json_object_and_content_type(self):
        status, _ = self.request("/pair", [], content_type="application/json")
        self.assertEqual(status, 400)
        status, _ = self.request("/pair", {}, content_type="text/plain")
        self.assertEqual(status, 415)
        status, _ = self.request("/missing", {})
        self.assertEqual(status, 404)

    def test_cli_module_is_available(self):
        result = subprocess.run([sys.executable, "-m", "harness_companion", "pair", "--help"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--root", result.stdout)
        self.assertIn("--grant", result.stdout)


if __name__ == "__main__":
    unittest.main()
