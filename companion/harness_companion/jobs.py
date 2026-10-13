"""Bounded, owner-scoped command jobs. Records live only for this node process."""

from __future__ import annotations

from dataclasses import dataclass
import math
import os
import subprocess
import threading
import time
import uuid

from .errors import NodeError

MAX_CONCURRENT_JOBS = 8
MAX_RETAINED_JOBS = 128
JOB_RETENTION_SECONDS = 3600
MAX_JOB_OUTPUT = 64 * 1024


@dataclass
class Job:
    job_id: str
    owner: str
    command: tuple[str, ...] | None = None
    timeout: float | None = None
    state: str = "queued"
    result: dict | None = None
    finished_at: float | None = None
    cancel_requested: bool = False
    process: subprocess.Popen | None = None
    worker: threading.Thread | None = None


class JobRegistry:
    def __init__(self, node):
        self.node = node
        # The shared lock makes registration/spawn atomic with revocation and node shutdown.
        self.lock = node.lock
        self.records: dict[str, Job] = {}

    @staticmethod
    def _job_id(body: dict) -> str:
        value = body.get("jobID")
        if not isinstance(value, str) or len(value) != 36:
            raise NodeError("invalid_request", "jobID must be a UUID")
        try:
            return str(uuid.UUID(value))
        except (ValueError, AttributeError) as error:
            raise NodeError("invalid_request", "jobID must be a UUID") from error

    @staticmethod
    def _command(body: dict) -> tuple[tuple[str, ...], float]:
        command, timeout = body.get("command"), body.get("timeout")
        try:
            valid_command = (isinstance(command, list) and 1 <= len(command) <= 128 and
                all(isinstance(arg, str) and "\0" not in arg and len(arg.encode("utf-8")) <= 8192 for arg in command) and bool(command[0]))
        except UnicodeEncodeError:
            valid_command = False
        if (set(body) != {"jobID", "command", "timeout"} or
                not valid_command or isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or
                not math.isfinite(timeout) or not .1 <= timeout <= 1800):
            raise NodeError("invalid_request", "Use jobID, an argument array, and an explicit timeout from 0.1 to 1800 seconds")
        return tuple(command), float(timeout)

    def _authorize_owner(self, owner: str) -> None:
        device = next((item for item in self.node.state["devices"] if item["id"] == owner), None)
        if device is None or device["root"] != str(self.node.root):
            raise NodeError("unauthorized", "A paired device token is required", 401)
        if "execute" not in device["capabilities"] or "execute" not in self.node.grants:
            raise NodeError("capability_denied", "This device has no grant for this capability", 403)

    def _prune(self) -> None:
        cutoff = self.node.clock() - JOB_RETENTION_SECONDS
        for job_id, job in list(self.records.items()):
            if job.finished_at is not None and job.finished_at < cutoff:
                del self.records[job_id]

    def _find(self, owner: str, job_id: str) -> Job | None:
        job = self.records.get(job_id)
        if job is not None and job.owner != owner:
            raise NodeError("job_not_found", "Job was not found", 404)
        return job

    @staticmethod
    def _snapshot(job: Job) -> dict:
        value = {"jobID": job.job_id, "state": job.state}
        if job.result is not None:
            value["result"] = job.result.copy()
        return value

    @staticmethod
    def _empty_result(message="") -> dict:
        return {"exitCode": -1, "stdout": "", "stderr": message, "truncated": False, "timedOut": False}

    def start(self, owner: str, body: dict) -> dict:
        job_id = self._job_id(body)
        with self.lock:
            self._authorize_owner(owner)
            self._prune()
            job = self._find(owner, job_id)
            command, timeout = self._command(body)
            if job is not None:
                if job.command is None:
                    # Cancellation may beat the first start HTTP request. Bind its signature but
                    # never launch a command for this retained cancellation tombstone.
                    job.command, job.timeout = command, timeout
                elif (job.command, job.timeout) != (command, timeout):
                    raise NodeError("job_conflict", "This jobID already belongs to a different request", 409)
                return self._snapshot(job)
            if self.node._closing:
                raise NodeError("node_stopping", "The companion is stopping", 503)
            if len(self.records) >= MAX_RETAINED_JOBS:
                raise NodeError("job_capacity", "The companion's retained job limit is full; retry later", 429)
            if sum(job.finished_at is None for job in self.records.values()) >= MAX_CONCURRENT_JOBS:
                raise NodeError("job_capacity", "The companion is already running its maximum number of jobs", 429)
            job = Job(job_id, owner, command, timeout)
            self.records[job_id] = job
            job.worker = threading.Thread(target=self._run, args=(job,), name="harness-job", daemon=True)
            try:
                job.worker.start()
            except RuntimeError as error:
                job.state = "failed"
                job.result = self._empty_result("Job worker could not be started")
                job.finished_at = self.node.clock()
            return self._snapshot(job)

    def status(self, owner: str, body: dict) -> dict:
        if set(body) != {"jobID"}:
            raise NodeError("invalid_request", "Use only jobID for status")
        job_id = self._job_id(body)
        with self.lock:
            self._authorize_owner(owner)
            self._prune()
            job = self._find(owner, job_id)
            if job is None:
                raise NodeError("job_not_found", "Job was not found", 404)
            return self._snapshot(job)

    def cancel(self, owner: str, body: dict) -> dict:
        if set(body) != {"jobID"}:
            raise NodeError("invalid_request", "Use only jobID for cancellation")
        job_id = self._job_id(body)
        with self.lock:
            self._authorize_owner(owner)
            self._prune()
            job = self._find(owner, job_id)
            if job is None:
                if len(self.records) >= MAX_RETAINED_JOBS:
                    raise NodeError("job_capacity", "The companion's retained job limit is full; retry later", 429)
                job = Job(job_id, owner)
                self.records[job_id] = job
            process = self._cancel_locked(job)
        if process is not None:
            self.node._terminate(process)
        # Return promptly; the collector publishes a final result once pipes are drained.
        with self.lock:
            return self._snapshot(job)

    def _cancel_locked(self, job: Job) -> subprocess.Popen | None:
        if job.finished_at is not None:
            return None
        job.cancel_requested = True
        job.state = "cancelled"
        if job.process is None:
            job.result = self._empty_result()
            job.finished_at = self.node.clock()
        return job.process

    def cancel_owner(self, owner: str) -> None:
        self._cancel_all(owner)

    def close(self) -> None:
        self._cancel_all(None)
        deadline = time.monotonic() + 4
        with self.lock:
            workers = [job.worker for job in self.records.values() if job.worker is not None]
        for worker in workers:
            if worker.is_alive():
                worker.join(timeout=max(0, deadline - time.monotonic()))

    def _cancel_all(self, owner: str | None) -> None:
        with self.lock:
            processes = [process for job in self.records.values() if owner is None or job.owner == owner
                         if (process := self._cancel_locked(job)) is not None]
        for process in processes:
            self.node._terminate(process)

    def _run(self, job: Job) -> None:
        try:
            with self.lock:
                # A cancel, revocation or shutdown can win before this worker is scheduled.
                if job.cancel_requested or self.node._closing:
                    self._cancel_locked(job)
                    return
                try:
                    self._authorize_owner(job.owner)
                except NodeError:
                    self._cancel_locked(job)
                    return
                process = subprocess.Popen(job.command, cwd=self.node.root, shell=False,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=(os.name == "posix"))
                job.process = process
                self.node._processes.add(process)
                job.state = "running"
        except OSError:
            with self.lock:
                job.state = "failed"
                job.result = self._empty_result("Command could not be started")
                job.finished_at = self.node.clock()
            return

        outputs = [bytearray(), bytearray()]
        truncated = [False, False]

        def drain(stream, index):
            with stream:
                while chunk := stream.read(8192):
                    space = MAX_JOB_OUTPUT - len(outputs[index])
                    outputs[index].extend(chunk[:space])
                    if len(chunk) > space:
                        truncated[index] = True

        readers = [threading.Thread(target=drain, args=(stream, i), daemon=True)
                   for i, stream in enumerate((process.stdout, process.stderr))]
        for reader in readers:
            reader.start()
        timed_out = False
        try:
            process.wait(timeout=job.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            # Also kill descendants holding stdout/stderr open after their parent has exited.
            self.node._terminate(process)
            process.wait(timeout=3)
        for reader in readers:
            reader.join(timeout=3)
        result = {"exitCode": process.returncode,
                  "stdout": outputs[0].decode("utf-8", errors="replace"),
                  "stderr": outputs[1].decode("utf-8", errors="replace"),
                  "truncated": any(truncated), "timedOut": timed_out}
        with self.lock:
            self.node._processes.discard(process)
            job.process = None
            if job.cancel_requested:
                job.state = "cancelled"
                result["timedOut"] = False
            else:
                job.state = "completed" if process.returncode == 0 and not timed_out else "failed"
            job.result = result
            job.finished_at = self.node.clock()
