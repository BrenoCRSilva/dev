#!/usr/bin/env python3
# Manual check, not part of the fixtures: starts the installed claude interactively
# in a folder it already trusts, with a status line that records its input and
# runs task-statusline.sh on it. It sends no prompt, so it makes no model call.
# Prints the status JSON fields the status line reads, and the line it rendered.
#
#   python3 -I scripts/tests/statusline-live-probe.py <trusted-dir>
import json
import os
import pty
import select
import shlex
import signal
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STATUS = os.path.join(ROOT, "env", ".config", "tmux", "scripts", "task-statusline.sh")


def drain(fd, seconds):
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.25)
        if ready:
            try:
                os.read(fd, 65536)
            except OSError:
                return


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    cwd = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory() as tmp:
        dump = os.path.join(tmp, "input.json")
        line_file = os.path.join(tmp, "line.txt")
        settings = os.path.join(tmp, "settings.json")
        command = f"tee {shlex.quote(dump)} | bash {shlex.quote(STATUS)} > {shlex.quote(line_file)}"
        with open(settings, "w") as handle:
            json.dump({"statusLine": {"type": "command", "command": command}}, handle)

        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            os.execvp("claude", ["claude", "--settings", settings])
        deadline = time.time() + 40
        while time.time() < deadline:
            drain(fd, 0.5)
            if os.path.exists(dump) and os.path.exists(line_file) and os.path.getsize(line_file) > 0:
                break
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

        if not os.path.exists(dump):
            sys.exit("FAIL: claude did not run the status line")
        payload = json.load(open(dump))
        print("status JSON fields:")
        for key in ("model", "cost", "context_window", "prompt_cache"):
            print(f"  {key}: {json.dumps(payload.get(key), sort_keys=True)[:160]}")
        rendered = open(line_file).read().strip() if os.path.exists(line_file) else ""
        print("rendered:", rendered)
        if not rendered.startswith("orchestrator |"):
            sys.exit("FAIL: the status line script did not render")
        print("PASS: live status JSON read and rendered")


if __name__ == "__main__":
    main()
