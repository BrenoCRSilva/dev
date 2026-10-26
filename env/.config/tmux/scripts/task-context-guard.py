#!/usr/bin/env python3
"""C4 context guard: a UserPromptSubmit and PostToolUse hook for the orchestrator, wired in
task-roles/orchestrator.claude-settings.json. It reads the prompt size of the newest main-thread assistant
turn from the transcript tail (input + cache read + cache write). From 400k tokens it adds one soft line,
once per crossing: run /compact at the next checkpoint. It never asks for a restart: native compaction keeps
the session, and task-compact-context.py restores its state after it. The line is repeated only after the
prompt has dropped below the checkpoint (a compaction does that) and crossed it again. Silent below. The
checkpoint is env-overridable (TASK_CONTEXT_CHECKPOINT, TASK_CONTEXT_STATE).
Any error exits 0 with no output: a hook must never block the session. Stdlib only.
"""
import json
import os
import sys
from pathlib import Path

TAIL_BYTES = 1 << 20  # the newest turn sits at the end; tool results can be large
STATE_ROOT = Path(os.environ.get("TASK_CONTEXT_STATE") or Path.home() / ".local/state/task-agents/context-guard")


def prompt_tokens(transcript):
    """Prompt size of the newest main-thread assistant turn, or None when the tail has none."""
    with open(transcript, "rb") as handle:
        size = handle.seek(0, os.SEEK_END)
        handle.seek(max(0, size - TAIL_BYTES))
        lines = handle.read().split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]  # the first line may start mid-record
    for line in reversed(lines):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("type") != "assistant" or record.get("isSidechain"):
            continue
        usage = (record.get("message") or {}).get("usage") or {}
        if usage:
            return sum(usage.get(key) or 0 for key in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return None


def guard(payload):
    """The context line to add for this event, or None."""
    checkpoint = int(os.environ.get("TASK_CONTEXT_CHECKPOINT") or 400_000)
    tokens = prompt_tokens(payload["transcript_path"])
    flag = STATE_ROOT / f"{Path(str(payload['session_id'])).name}.reminded"
    if tokens is None or tokens < checkpoint:
        flag.unlink(missing_ok=True)
        return None
    if flag.exists():
        return None
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    flag.touch()
    return (f"Context is {tokens // 1000}k: run /compact at your next checkpoint, after AGENTS.md is up to date; "
            "the SessionStart hook restores the Decisions, the plan and the open wakes.")


def main():
    try:
        payload = json.load(sys.stdin)
        text = guard(payload)
        if text:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": payload["hook_event_name"], "additionalContext": text}}))
    except Exception:  # a hook must never block the session
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
