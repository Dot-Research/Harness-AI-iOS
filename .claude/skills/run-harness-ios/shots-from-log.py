#!/usr/bin/env python3
"""Decode SHOT-BEGIN/SHOT-END blocks from a Simulator drive job log into JPEG files.

Usage: shots-from-log.py <job-log> <out-dir>
<job-log> is the plain log, or the file the GitHub MCP get_job_logs tool saved ({"logs_content": ...}).
GitHub log lines start with a timestamp ("2026-10-15T02:52:44.9511090Z "); it is stripped.
"""
import base64, json, pathlib, re, sys

log, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
stamp = re.compile(r"^\S*\d{4}-\d\d-\d\dT[\d:.]+Z ")
name, chunks = None, []
text = log.read_text(errors="replace")
try:
    text = json.loads(text)["logs_content"]
except (ValueError, KeyError, TypeError):
    pass
for raw in text.splitlines():
    line = stamp.sub("", raw).strip()
    if line.startswith("SHOT-BEGIN "):
        name, chunks = line.split(" ", 1)[1], []
    elif line == "SHOT-END" and name:
        (out / name).write_bytes(base64.b64decode("".join(chunks)))
        print(out / name)
        name = None
    elif name:
        chunks.append(line)
