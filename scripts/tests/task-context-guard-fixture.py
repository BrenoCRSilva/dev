#!/usr/bin/env python3
"""Offline checks for task-context-guard.py (C4). Runs the real hook on synthetic transcripts in a
temporary folder: one soft line at the 400k checkpoint, no repeat while above it, a reset once the prompt
drops below it (a compaction), a level that never asks for a restart, sidechain turns ignored, the env
override, a turn beyond the tail, and silence on bad input."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "env/.config/tmux/scripts/task-context-guard.py"


def turn(total, sidechain=False):
    """One assistant record whose prompt is `total` tokens, split over input, cache read and cache write."""
    cache_read = total // 2
    usage = {"input_tokens": 7, "cache_read_input_tokens": cache_read,
             "cache_creation_input_tokens": total - 7 - cache_read, "output_tokens": 50}
    return json.dumps({"type": "assistant", "isSidechain": sidechain, "message": {"usage": usage}}) + "\n"


def write(path, *records):
    path.write_text("".join(records), encoding="utf-8")


def run(transcript, state, event="PostToolUse", env=None, stdin=None):
    """The hook's additionalContext line, or None when it is silent."""
    payload = {"session_id": "fixture-session", "transcript_path": str(transcript), "hook_event_name": event}
    text = json.dumps(payload) if stdin is None else stdin
    proc = subprocess.run([sys.executable, "-I", str(GUARD)], input=text, capture_output=True, text=True,
                          env={**os.environ, "TASK_CONTEXT_STATE": str(state), **(env or {})})
    assert proc.returncode == 0, proc.stderr
    if not proc.stdout.strip():
        return None
    out = json.loads(proc.stdout)["hookSpecificOutput"]
    assert out["hookEventName"] == event, out
    return out["additionalContext"]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        transcript = tmp / "session.jsonl"
        state = tmp / "state"

        write(transcript, json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
        assert run(transcript, state) is None, "no assistant usage yet: silent"

        write(transcript, turn(399_999))
        assert run(transcript, state) is None, "below 400k: silent"

        # One soft line at the checkpoint, and it suggests /compact, never a restart.
        write(transcript, turn(400_000))
        line = run(transcript, state)
        assert line and line.startswith("Context is 400k") and "/compact" in line, line
        assert "restart" not in line and "\n" not in line, line

        # Above the checkpoint the line is not repeated, however far the prompt grows.
        write(transcript, turn(430_000))
        assert run(transcript, state) is None, "above 400k: no repeat"
        write(transcript, turn(600_000))
        assert run(transcript, state) is None, "grew 200k: still no repeat"

        # A compaction drops the prompt below the checkpoint: the flag clears, and a new crossing reminds again.
        write(transcript, turn(10_000))
        assert run(transcript, state) is None
        assert not (state / "fixture-session.reminded").exists(), "flag cleared below checkpoint"
        write(transcript, turn(405_000))
        assert run(transcript, state), "first crossing after a compaction reminds"

        # A sidechain turn (a subagent's) is not the orchestrator's prompt size.
        write(transcript, turn(10_000), turn(900_000, sidechain=True))
        assert run(transcript, state) is None, "sidechain turn ignored"

        # The event name is echoed back, so the same guard serves UserPromptSubmit.
        write(transcript, turn(10_000))
        run(transcript, tmp / "prompt")
        write(transcript, turn(401_000))
        assert run(transcript, tmp / "prompt", event="UserPromptSubmit"), "UserPromptSubmit emits"

        # The env override moves the checkpoint.
        fresh = tmp / "fresh"
        env = {"TASK_CONTEXT_CHECKPOINT": "50000"}
        write(transcript, turn(49_999))
        assert run(transcript, fresh, env=env) is None, "below the overridden checkpoint: silent"
        write(transcript, turn(55_000))
        line = run(transcript, fresh, env=env)
        assert line and line.startswith("Context is 55k"), "overridden checkpoint"
        assert run(transcript, fresh, env=env) is None, "overridden checkpoint: no repeat"

        # A large non-assistant record before the newest turn: the tail still finds the turn.
        big = json.dumps({"type": "user", "message": {"content": "x" * (2 << 20)}}) + "\n"
        write(transcript, big, turn(450_000))
        line = run(transcript, tmp / "big")
        assert line and line.startswith("Context is 450k"), "turn found past the tail"

        # Silent on a missing transcript and on bad input; never a failed hook.
        assert run(tmp / "missing.jsonl", state) is None
        assert run(transcript, state, stdin="not json") is None
    print("task-context-guard fixture: ok")


if __name__ == "__main__":
    main()
