#!/usr/bin/env python3
"""Offline checks for task-compact-context.py (C5). Runs the real SessionStart hook on a temporary task root:
the Decisions and Plan / status sections only, a long Decisions section capped under 10,000 characters, the
digest and an open wake from the real state.db, the handoff file when present, a note (not a failure) when
AGENTS.md is missing or the input is bad."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "env/.config/tmux/scripts"
HOOK = SCRIPTS / "task-compact-context.py"
sys.path.insert(0, str(SCRIPTS))

import task_plan  # noqa: E402
import task_state  # noqa: E402

AGENTS_MD = """# demo

## Goal
GOAL-TEXT

## Repos
REPO-LIST-TEXT

## Repo modes

### Worker repos
- **dotfiles** — agent `worker-dotfiles`.

## Decisions
- 2026-10-26: user chose Opus 5.5 for every role.

## Plan / status
1. `a` (worker-dotfiles): in progress.

## Notes for agents
NOTES-TEXT
"""


def check(label, condition, detail=None):
    if condition:
        print(f"ok   {label}")
    else:
        print(f"FAIL {label} {'' if detail is None else detail}")
        sys.exit(1)


def run(stdin, hook=HOOK, env=None):
    """The hook's output, parsed, and its exit code. TASK_ROOT is removed so the walk from cwd decides, unless env sets it."""
    proc = subprocess.run([sys.executable, str(hook)], input=stdin, capture_output=True, text=True,
                          timeout=60, env={**{k: v for k, v in os.environ.items() if k != "TASK_ROOT"}, **(env or {})})
    out = json.loads(proc.stdout)["hookSpecificOutput"] if proc.stdout.strip() else {}
    return proc.returncode, out


def payload(root):
    return json.dumps({"session_id": "fixture", "cwd": str(root), "hook_event_name": "SessionStart", "source": "compact"})


def fixture_task(tmp):
    """A temporary task root with one plan node, so the digest and wakes run for real."""
    root = Path(tmp) / "task"
    root.mkdir()
    (root / "AGENTS.md").write_text(AGENTS_MD, encoding="utf-8")
    plan = root / "plan"
    plan.mkdir()
    (plan / "dag.toml").write_text('[[node]]\nid = "a"\nagent = "worker-dotfiles"\nspec = "specs/a.md"\nscope = ["env/**"]\n',
                                   encoding="utf-8")
    (root / "specs").mkdir()
    (root / "specs" / "a.md").write_text("# a\n", encoding="utf-8")
    return root


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = fixture_task(tmp)
        plan = root / "plan"

        code, out = run(payload(root))
        text = out.get("additionalContext", "")
        check("exit 0 and a SessionStart packet", code == 0 and out.get("hookEventName") == "SessionStart", (code, out))
        check("names the task root", f"Task root: {root}" in text, text)
        check("keeps Decisions", "## Decisions" in text and "Opus 5.5 for every role" in text, text)
        check("keeps Plan / status", "## Plan / status" in text and "in progress" in text, text)
        check("leaves out Repos and Notes", "REPO-LIST-TEXT" not in text and "NOTES-TEXT" not in text and "GOAL-TEXT" not in text, text)
        check("no handoff file: no handoff part", "Handoff" not in text, text)
        check("digest and wakes are listed", "Digest:" in text and "Open wakes:" in text, text)

        # The dispatcher's state: an open wake on node a, from the real state.db, shows in the packet.
        conn = task_state.connect(root)
        try:
            task_state.reconcile(conn, task_plan.load_plan(root))
            task_state.install(conn, "a", {"turns": 60, "prompt_k": 300})
            task_state.wake(conn, "a", "opus", "checkpoint", "A is in; continue to B?")
        finally:
            conn.close()
        code, out = run(payload(root))
        text = out.get("additionalContext", "")
        check("an open wake from state.db is in the packet", "wake 1 opus a checkpoint: A is in; continue to B?" in text, text)

        # A handoff file is added after the state, capped.
        (plan / "orchestrator-handoff.md").write_text("HANDOFF-TEXT\n", encoding="utf-8")
        code, out = run(payload(root))
        text = out.get("additionalContext", "")
        check("handoff file is added", "Handoff (plan/orchestrator-handoff.md)" in text and "HANDOFF-TEXT" in text, text)

        # A long Decisions section is capped, and the packet stays under 10,000 characters.
        long_decisions = "## Decisions\n" + "".join(f"- 2026-10-26: decision {i} " + "x" * 200 + "\n" for i in range(200))
        (root / "AGENTS.md").write_text(AGENTS_MD.replace("## Decisions\n- 2026-10-26: user chose Opus 5.5 for every role.\n", long_decisions),
                                        encoding="utf-8")
        (plan / "orchestrator-handoff.md").write_text("H" * 50_000, encoding="utf-8")
        code, out = run(payload(root))
        text = out.get("additionalContext", "")
        check("packet under 10,000 characters", len(text) < 10_000, len(text))
        check("long part is cut with a marker", "[cut: the full text is in the file]" in text, len(text))
        check("the plan still follows a long Decisions part", "## Plan / status" in text, len(text))

        # The task root is found from a subfolder of the task, and from TASK_ROOT when cwd is elsewhere.
        code, out = run(payload(root / "specs"))
        text = out.get("additionalContext", "")
        check("from a subfolder: the task root is found", code == 0 and f"Task root: {root}" in text and "## Decisions" in text, text)
        empty = Path(tmp) / "empty"
        empty.mkdir()
        code, out = run(payload(empty), env={"TASK_ROOT": str(root)})
        text = out.get("additionalContext", "")
        check("TASK_ROOT from elsewhere: the task root is used", code == 0 and f"Task root: {root}" in text, text)

        # A slow digest and a failing wakes command are notes; Decisions and Plan still print.
        bin_dir = Path(tmp) / "bin"
        bin_dir.mkdir()
        shutil.copy(HOOK, bin_dir / HOOK.name)
        (bin_dir / "task-dispatch.py").write_text(
            "import sys, time\nif sys.argv[1] == 'digest':\n    time.sleep(60)\nsys.exit(2)\n", encoding="utf-8")
        code, out = run(payload(root), hook=bin_dir / HOOK.name)
        text = out.get("additionalContext", "")
        check("slow digest and failing wakes: notes, exit 0", code == 0 and "digest: unavailable (timeout)" in text
              and "wakes: unavailable (exit 2)" in text, text)
        check("the Decisions and Plan parts still print", "## Decisions" in text and "## Plan / status" in text, text)

        # Fail soft: no AGENTS.md is a note, bad input is a note, both exit 0.
        code, out = run(payload(empty))
        check("no AGENTS.md: a note, exit 0", code == 0 and "no AGENTS.md" in out.get("additionalContext", ""), out)
        code, out = run("not json")
        check("bad input: a note, exit 0", code == 0 and "unavailable" in out.get("additionalContext", ""), out)
    print("task-compact-context fixture: ok")


if __name__ == "__main__":
    main()
