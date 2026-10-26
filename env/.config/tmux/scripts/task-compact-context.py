#!/usr/bin/env python3
"""C5 compaction packet: a SessionStart hook for the orchestrator, matchers compact and resume, wired in
task-roles/orchestrator.claude-settings.json. After a native /compact, or on a resumed session, it adds the
task's curated state as additionalContext, under 10,000 characters: the task root, the Decisions and Plan /
status sections of AGENTS.md, the dispatcher's digest and open wakes, and plan/orchestrator-handoff.md when it
exists. Each part is capped, so a long part cannot push out the ones after it. Fails soft: on any error it
adds a one-line note and exits 0. Stdlib only.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

LIMIT = 9_500  # under the 10,000 characters the packet may use, with room for the cut marker
DISPATCH = Path(__file__).resolve().with_name("task-dispatch.py")
DISPATCH_TIMEOUT = 6  # the hook has 20s; two dispatcher calls must fit with the file reads
CAPS = {"decisions": 2500, "plan": 2500, "digest": 1500, "wakes": 1000, "handoff": 1500}


def section(text, heading):
    """The part of AGENTS.md under `## heading`, up to the next level-2 heading; empty when there is none."""
    for part in re.split(r"(?m)^(?=## )", text):
        if part.split("\n", 1)[0].strip() == f"## {heading}":
            return part.rstrip()
    return ""


def capped(text, limit):
    return text if len(text) <= limit else text[:limit].rstrip() + "\n[cut: the full text is in the file]"


def dispatch(root, command):
    """One dispatcher command's output; a note in its place when it fails or times out, so the other parts still print."""
    try:
        proc = subprocess.run([sys.executable, str(DISPATCH), command, "--task-root", str(root)],
                              capture_output=True, text=True, timeout=DISPATCH_TIMEOUT)
    except subprocess.TimeoutExpired:
        return f"{command}: unavailable (timeout)"
    except OSError as error:
        return f"{command}: unavailable ({type(error).__name__})"
    if proc.returncode and not proc.stdout.strip():
        return f"{command}: unavailable (exit {proc.returncode})"
    return proc.stdout.strip() or f"{command}: no output"


def packet(root):
    agents = (root / "AGENTS.md").read_text(encoding="utf-8")
    handoff = root / "plan" / "orchestrator-handoff.md"
    parts = [
        f"Task root: {root}",
        capped(section(agents, "Decisions"), CAPS["decisions"]),
        capped(section(agents, "Plan / status"), CAPS["plan"]),
        "Digest:\n" + capped(dispatch(root, "digest"), CAPS["digest"]),
        "Open wakes:\n" + capped(dispatch(root, "wakes"), CAPS["wakes"]),
    ]
    if handoff.is_file():
        parts.append("Handoff (plan/orchestrator-handoff.md):\n" + capped(handoff.read_text(encoding="utf-8"), CAPS["handoff"]))
    return "\n\n".join(part for part in parts if part)[:LIMIT]


def task_root(cwd):
    """TASK_ROOT when it names a task, else the first folder from cwd upward that has an AGENTS.md; None when there is none."""
    candidates = [Path(os.environ["TASK_ROOT"])] if os.environ.get("TASK_ROOT") else []
    candidates += [cwd, *cwd.parents]
    return next((folder for folder in candidates if (folder / "AGENTS.md").is_file()), None)


def main():
    try:
        payload = json.load(sys.stdin)
        cwd = Path(payload.get("cwd") or Path.cwd())
        root = task_root(cwd)
        if root:
            text = packet(root)
        else:
            text = f"Compaction packet: no AGENTS.md at or above {cwd}. Read the task's AGENTS.md, then run task-dispatch.py digest and wakes."
    except Exception as error:  # fail soft: the session goes on with a note
        text = f"Compaction packet unavailable ({type(error).__name__}). Read AGENTS.md, then run task-dispatch.py digest and wakes."
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
