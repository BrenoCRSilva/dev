#!/usr/bin/env python3
"""Offline checks for task-context-guard.py (C4). Runs the real hook on synthetic transcripts in a
temporary folder: thresholds, one line per 20k growth, a level change, sidechain turns ignored, env
overrides, a reset below the checkpoint, a turn beyond the tail, and silence on bad input."""
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

        write(transcript, turn(119_999))
        assert run(transcript, state) is None, "below 120k: silent"

        # Checkpoint level at 120k, then silent for 10k of growth, then again at 20k of growth.
        write(transcript, turn(120_000))
        line = run(transcript, state)
        assert line and line.startswith("Context is 120k") and "restart" not in line, line
        assert "\n" not in line, "one line"
        write(transcript, turn(130_000))
        assert run(transcript, state) is None, "grew 10k: no repeat"
        write(transcript, turn(140_000))
        assert run(transcript, state), "grew 20k: repeat"

        # Restart level at 150k is a level change, so it is reported at once.
        write(transcript, turn(150_000))
        line = run(transcript, state)
        assert line and "task-agent.sh restart orchestrator" in line and "finish" in line, line
        write(transcript, turn(160_000))
        assert run(transcript, state) is None, "restart level, grew 10k: no repeat"
        write(transcript, turn(170_000))
        assert run(transcript, state), "restart level, grew 20k: repeat"

        # A sidechain turn (a subagent's) is not the orchestrator's prompt size.
        write(transcript, turn(170_000), turn(500_000, sidechain=True))
        assert run(transcript, state) is None, "sidechain turn ignored"

        # Reset: a session that drops below the checkpoint starts over.
        write(transcript, turn(10_000))
        assert run(transcript, state) is None
        assert not (state / "fixture-session.json").exists(), "state cleared below checkpoint"
        write(transcript, turn(125_000))
        line = run(transcript, state)
        assert line and line.startswith("Context is 125k"), "first reminder after reset"

        # The event name is echoed back, so the same guard serves UserPromptSubmit.
        write(transcript, turn(121_000))
        assert run(transcript, tmp / "prompt", event="UserPromptSubmit"), "UserPromptSubmit emits"

        # Env overrides move both thresholds and the growth step.
        fresh = tmp / "fresh"
        env = {"TASK_CONTEXT_CHECKPOINT": "50000", "TASK_CONTEXT_RESTART": "60000", "TASK_CONTEXT_STEP": "1000"}
        write(transcript, turn(55_000))
        assert run(transcript, fresh, env=env), "overridden checkpoint"
        assert run(transcript, fresh, env=env) is None, "no growth: silent"
        write(transcript, turn(56_000))
        assert run(transcript, fresh, env=env), "1k growth with the overridden step"
        write(transcript, turn(61_000))
        line = run(transcript, fresh, env=env)
        assert line and "restart orchestrator" in line, "overridden restart threshold"

        # A large non-assistant record before the newest turn: the tail still finds the turn.
        big = json.dumps({"type": "user", "message": {"content": "x" * (2 << 20)}}) + "\n"
        write(transcript, big, turn(180_000))
        line = run(transcript, tmp / "big")
        assert line and line.startswith("Context is 180k"), "turn found past the tail"

        # Silent on a missing transcript and on bad input; never a failed hook.
        assert run(tmp / "missing.jsonl", state) is None
        assert run(transcript, state, stdin="not json") is None
    print("task-context-guard fixture: ok")


if __name__ == "__main__":
    main()
