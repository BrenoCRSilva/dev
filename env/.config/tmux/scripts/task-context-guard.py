#!/usr/bin/env python3
"""C4 context guard: a UserPromptSubmit and PostToolUse hook for the orchestrator, wired in
task-roles/orchestrator.claude-settings.json. It reads the prompt size of the newest main-thread assistant
turn from the transcript tail (input + cache read + cache write). From 120k tokens it adds one line of
context: a checkpoint reminder, and from 150k a restart request. A line is repeated only after the prompt has
grown by 20k, or when the level changes. Silent below the checkpoint. Thresholds and the state folder are
env-overridable (TASK_CONTEXT_CHECKPOINT, TASK_CONTEXT_RESTART, TASK_CONTEXT_STEP, TASK_CONTEXT_STATE).
Any error exits 0 with no output: a hook must never block the session. Stdlib only.
"""
import json
import os
import sys
from pathlib import Path

TAIL_BYTES = 1 << 20  # the newest turn sits at the end; tool results can be large
STATE_ROOT = Path(os.environ.get("TASK_CONTEXT_STATE") or Path.home() / ".local/state/task-agents/context-guard")


def threshold(name, default):
    return int(os.environ.get(name) or default)


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
    checkpoint = threshold("TASK_CONTEXT_CHECKPOINT", 120_000)
    restart = threshold("TASK_CONTEXT_RESTART", 150_000)
    step = threshold("TASK_CONTEXT_STEP", 20_000)
    tokens = prompt_tokens(payload["transcript_path"])
    state_file = STATE_ROOT / f"{Path(str(payload['session_id'])).name}.json"
    if tokens is None or tokens < checkpoint:
        state_file.unlink(missing_ok=True)
        return None
    level = 2 if tokens >= restart else 1
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    if state.get("level") == level and tokens - state.get("tokens", 0) < step:
        return None
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps({"tokens": tokens, "level": level}))
    if level == 1:
        return f"Context is {tokens // 1000}k: checkpoint AGENTS.md at the next step boundary and keep command output short."
    return (f"Context is {tokens // 1000}k: checkpoint AGENTS.md (decisions, status), then run "
            "`~/.config/tmux/scripts/task-agent.sh restart orchestrator` if no user question is pending and work "
            "remains; otherwise finish the current task.")


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
