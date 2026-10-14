"""Job integration tests use the real TLS handler and real operating-system processes."""

import concurrent.futures
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock
import uuid

import test_node


class TLSJobTests(unittest.TestCase):
    setUpClass = classmethod(test_node.TLSNodeTests.setUpClass.__func__)
    tearDownClass = classmethod(test_node.TLSNodeTests.tearDownClass.__func__)
    setUp = test_node.TLSNodeTests.setUp
    tearDown = test_node.TLSNodeTests.tearDown
    request = test_node.TLSNodeTests.request
    pair = test_node.TLSNodeTests.pair

    def job(self, source, timeout=60):
        return {"jobID": str(uuid.uuid4()), "command": [sys.executable, "-c", source], "timeout": timeout}

    def start(self, body, bearer=None):
        return self.request("/tools/jobs/start", body, bearer or self.bearer)

    def wait_result(self, job_id, bearer=None, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, value = self.request("/tools/jobs/status", {"jobID": job_id}, bearer or self.bearer)
            self.assertEqual(status, 200, value)
            if value["state"] in {"completed", "failed", "cancelled"} and "result" in value:
                return value
            time.sleep(0.01)
        self.fail("Job did not publish its final result")

    def wait_file(self, name, timeout=3):
        deadline = time.monotonic() + timeout
        path = self.root / name
        while time.monotonic() < deadline:
            if path.exists() and path.read_text():
                return path.read_text()
            time.sleep(0.01)
        self.fail(f"Process did not write {name}")

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
            if result.returncode or not result.stdout.strip() or result.stdout.strip().startswith("Z"):
                return
            time.sleep(0.01)
        self.fail(f"Process {pid} is still running")

    def second_pair(self, capabilities=None):
        with self.node.lock:
            self.node.pairing_token = secrets.token_urlsafe(32)
            self.node.expires_at = time.time() + 60
        return self.pair(capabilities)

    def test_start_returns_before_completion_and_reconnect_recovers_output(self):
        self.pair()
        body = self.job("import time; print('started', flush=True); time.sleep(.4); print('finished')", 1800)
        status, value = self.start(body)
        self.assertEqual(status, 200, value)
        self.assertEqual(value["jobID"], body["jobID"])
        self.assertIn(value["state"], {"queued", "running"})
        final = self.wait_result(body["jobID"])
        self.assertEqual(final["state"], "completed")
        self.assertEqual(final["result"], {"exitCode": 0, "stdout": "started\nfinished\n", "stderr": "", "truncated": False, "timedOut": False})
        self.assertEqual(self.start(body), (200, final))

    def test_concurrent_retries_execute_side_effect_once_and_conflicts_do_not_run(self):
        self.pair()
        body = self.job("from pathlib import Path; import time; p=Path('count'); p.write_text(p.read_text()+'x' if p.exists() else 'x'); time.sleep(.2)")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            responses = list(pool.map(lambda _: self.start(body), range(8)))
        self.assertTrue(all(status == 200 for status, _ in responses), responses)
        self.wait_result(body["jobID"])
        self.assertEqual((self.root / "count").read_text(), "x")
        for changed in ({**body, "command": [sys.executable, "-c", "print('different')"]}, {**body, "timeout": 20}):
            status, value = self.start(changed)
            self.assertEqual(status, 409, value)
        self.assertEqual((self.root / "count").read_text(), "x")

    def test_authentication_execute_grant_and_owner_are_required_for_every_job_route(self):
        owner = self.pair()
        body = self.job("print('private output')")
        self.assertEqual(self.start(body)[0], 200)
        self.wait_result(body["jobID"])
        other = self.second_pair()
        for route in ("start", "status", "cancel"):
            request = body if route == "start" else {"jobID": body["jobID"]}
            self.assertEqual(self.request("/tools/jobs/" + route, request)[0], 401)
            status, value = self.request("/tools/jobs/" + route, request, other["token"])
            self.assertEqual(status, 404, value)
            self.assertNotIn("private output", str(value))
        reader = self.second_pair(["readFile"])
        for route in ("start", "status", "cancel"):
            request = body if route == "start" else {"jobID": body["jobID"]}
            self.assertEqual(self.request("/tools/jobs/" + route, request, reader["token"])[0], 403)
        self.assertEqual(self.request("/tools/jobs/status", {"jobID": str(uuid.uuid4())}, owner["token"])[0], 404)

    def test_invalid_ids_commands_and_timeouts_never_start(self):
        self.pair()
        body = self.job("from pathlib import Path; Path('should-not-exist').touch()")
        invalid = [{**body, "jobID": "not-a-uuid"}, {**body, "command": "echo forbidden"}, {**body, "command": []}]
        invalid += [{**body, "timeout": timeout} for timeout in (0, .09, 1801, True, float("nan"), float("inf"))]
        invalid.append({key: value for key, value in body.items() if key != "timeout"})
        invalid += [{**body, "command": ["x" * 8193]}, {**body, "command": ["界" * 8192]}, {**body, "command": ["bad\ud800"]}]
        for request in invalid:
            status, value = self.start(request)
            self.assertEqual(status, 400, (request, value))
        self.assertFalse((self.root / "should-not-exist").exists())

    def test_status_and_cancel_accept_only_the_handle(self):
        self.pair()
        for route in ("status", "cancel"):
            status, value = self.request("/tools/jobs/" + route, {"jobID": str(uuid.uuid4()), "command": ["unused"]}, self.bearer)
            self.assertEqual(status, 400, value)

    def test_timeout_output_and_start_failures_are_reported(self):
        self.pair()
        body = self.job("import time; print('before timeout', flush=True); time.sleep(20)", .1)
        self.assertEqual(self.start(body)[0], 200)
        result = self.wait_result(body["jobID"])
        self.assertEqual(result["state"], "failed")
        self.assertTrue(result["result"]["timedOut"])
        self.assertIn("before timeout", result["result"]["stdout"])
        body = self.job("import sys; print('x'*200000); print('y'*200000, file=sys.stderr)")
        self.assertEqual(self.start(body)[0], 200)
        result = self.wait_result(body["jobID"])["result"]
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["stdout"].encode()), test_node.MAX_OUTPUT)
        self.assertEqual(len(result["stderr"].encode()), test_node.MAX_OUTPUT)
        body = {"jobID": str(uuid.uuid4()), "command": [str(self.root / "missing-command")], "timeout": 30}
        self.assertEqual(self.start(body)[0], 200)
        result = self.wait_result(body["jobID"])
        self.assertEqual(result["state"], "failed")
        self.assertNotEqual(result["result"]["exitCode"], 0)

    @unittest.skipUnless(os.name == "posix", "Process-tree assertions use POSIX ps")
    def test_cancel_ends_parent_and_child_and_retains_cancelled_result(self):
        self.pair()
        source = "import subprocess,sys,time,os; from pathlib import Path; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); Path('pids').write_text(str(os.getpid())+' '+str(child.pid)); print('ready',flush=True); time.sleep(60)"
        body = self.job(source)
        self.assertEqual(self.start(body)[0], 200)
        pids = [int(value) for value in self.wait_file("pids").split()]
        status, value = self.request("/tools/jobs/cancel", {"jobID": body["jobID"]}, self.bearer)
        self.assertEqual(status, 200, value)
        self.assertEqual(value["state"], "cancelled")
        final = self.wait_result(body["jobID"])
        self.assertEqual(final["state"], "cancelled")
        self.assertFalse(final["result"]["timedOut"])
        for pid in pids:
            self.assert_stopped(pid)
        self.assertEqual(self.start(body), (200, final))

    def test_cancel_before_spawn_prevents_command_side_effect(self):
        from harness_companion.jobs import JobRegistry
        self.pair()
        ready, proceed = threading.Event(), threading.Event()
        original = JobRegistry._run

        def delayed(registry, job):
            ready.set()
            proceed.wait(3)
            original(registry, job)

        body = self.job("from pathlib import Path; Path('spawned').touch()")
        with mock.patch.object(JobRegistry, "_run", delayed):
            try:
                self.assertEqual(self.start(body)[0], 200)
                self.assertTrue(ready.wait(2))
                status, value = self.request("/tools/jobs/cancel", {"jobID": body["jobID"]}, self.bearer)
                self.assertEqual(status, 200, value)
                self.assertEqual(value["state"], "cancelled")
            finally:
                proceed.set()
        self.wait_result(body["jobID"])
        self.assertFalse((self.root / "spawned").exists())

    def test_cancel_before_start_leaves_owner_scoped_tombstone(self):
        owner = self.pair()
        body = self.job("from pathlib import Path; Path('late-start').touch()")
        status, cancelled = self.request("/tools/jobs/cancel", {"jobID": body["jobID"]}, owner["token"])
        self.assertEqual(status, 200, cancelled)
        self.assertEqual(cancelled["state"], "cancelled")
        self.assertEqual(self.start(body, owner["token"]), (200, cancelled))
        self.assertFalse((self.root / "late-start").exists())
        conflict = {**body, "timeout": 120}
        self.assertEqual(self.start(conflict, owner["token"])[0], 409)
        other = self.second_pair()
        self.assertEqual(self.start(body, other["token"])[0], 404)
        self.assertEqual(self.request("/tools/jobs/cancel", {"jobID": body["jobID"]}, other["token"])[0], 404)

    @unittest.skipUnless(os.name == "posix", "Process-tree assertions use POSIX ps")
    def test_revoke_and_shutdown_kill_running_jobs(self):
        for action in ("revoke", "shutdown"):
            pair = self.pair() if self.node.pairing_token else self.second_pair()
            body = self.job("import os,time,subprocess,sys; from pathlib import Path; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); Path('" + action + "').write_text(str(os.getpid())+' '+str(child.pid)); time.sleep(60)")
            self.assertEqual(self.start(body)[0], 200)
            pids = [int(pid) for pid in self.wait_file(action).split()]
            if action == "revoke":
                self.assertTrue(self.node.revoke(pair["deviceId"]))
                self.assertEqual(self.request("/tools/jobs/status", {"jobID": body["jobID"]}, self.bearer)[0], 401)
            else:
                self.node.close()
            for pid in pids:
                self.assert_stopped(pid)

    def test_revoke_and_shutdown_before_spawn_prevent_side_effects(self):
        from harness_companion.jobs import JobRegistry
        for action in ("revoke", "shutdown"):
            pair = self.pair() if self.node.pairing_token else self.second_pair()
            ready, proceed = threading.Event(), threading.Event()
            original = JobRegistry._run
            def delayed(registry, job):
                ready.set()
                proceed.wait(5)
                original(registry, job)
            body = self.job("from pathlib import Path; Path('pre-spawn-" + action + "').touch()")
            with mock.patch.object(JobRegistry, "_run", delayed):
                try:
                    self.assertEqual(self.start(body)[0], 200)
                    self.assertTrue(ready.wait(2))
                    if action == "revoke":
                        self.node.revoke(pair["deviceId"])
                    else:
                        # close joins registered workers; unblock after it marks jobs cancelled.
                        closer = threading.Thread(target=self.node.close)
                        closer.start()
                        deadline = time.monotonic() + 2
                        while self.node.jobs.records[body["jobID"]].state != "cancelled" and time.monotonic() < deadline:
                            time.sleep(.01)
                        self.assertEqual(self.node.jobs.records[body["jobID"]].state, "cancelled")
                finally:
                    proceed.set()
            worker = self.node.jobs.records[body["jobID"]].worker
            worker.join(timeout=2)
            if action == "shutdown":
                closer.join(timeout=2)
            self.assertFalse((self.root / ("pre-spawn-" + action)).exists())

    def test_cancelled_handles_fill_actual_128_record_bound_without_eviction(self):
        self.pair()
        ids = [str(uuid.uuid4()) for _ in range(129)]
        for job_id in ids[:128]:
            self.assertEqual(self.request("/tools/jobs/cancel", {"jobID": job_id}, self.bearer)[0], 200)
        self.assertEqual(self.request("/tools/jobs/cancel", {"jobID": ids[-1]}, self.bearer)[0], 429)
        self.assertEqual(self.request("/tools/jobs/status", {"jobID": ids[0]}, self.bearer)[0], 200)

    def test_concurrent_and_retained_job_limits_preserve_known_job_ids(self):
        from harness_companion import jobs
        self.pair()
        bodies = [self.job("import time; time.sleep(60)") for _ in range(9)]
        for body in bodies[:8]:
            self.assertEqual(self.start(body)[0], 200)
        self.assertEqual(self.start(bodies[8])[0], 429)
        self.assertEqual(self.start(bodies[0])[0], 200)
        for body in bodies[:8]:
            self.request("/tools/jobs/cancel", {"jobID": body["jobID"]}, self.bearer)
            self.wait_result(body["jobID"])
        with mock.patch.object(jobs, "MAX_RETAINED_JOBS", 8):
            self.assertEqual(self.start(bodies[8])[0], 429)
            self.node.clock = lambda: time.time() + 3601
            self.assertEqual(self.start(bodies[8])[0], 200)
            self.assertEqual(self.request("/tools/jobs/status", {"jobID": bodies[0]["jobID"]}, self.bearer)[0], 404)


if __name__ == "__main__":
    unittest.main()
