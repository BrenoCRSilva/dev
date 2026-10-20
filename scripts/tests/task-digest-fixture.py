#!/usr/bin/env python3
"""Offline checks for `task-dispatch.py digest` (M4 part C, §6).

Builds a task's state.db with fixed times (the nodes, attempts, wakes, judgements and questions a checkpoint
packet reads) and the transcripts its spend reads under a temporary HOME, then runs the real CLI on it. Checks
the window since the last passed checkpoint, the spend per tier, the audit picks, open wakes and questions, jev's
shadow agreement, a task with no checkpoint, a missing state.db, and that the digest writes nothing.
Writes only inside a temporary folder.
"""
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DISPATCH = ROOT / "env/.config/tmux/scripts/task-dispatch.py"
sys.path.insert(0, str(ROOT / "env/.config/tmux/scripts"))
import task_state  # noqa: E402

SPEC = importlib.util.spec_from_file_location("task_spend_fixture", HERE / "task-spend-fixture.py")
assert SPEC is not None and SPEC.loader is not None
SPEND_FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SPEND_FIXTURE)
assistant = SPEND_FIXTURE.assistant
epoch = SPEND_FIXTURE.epoch
stamp = SPEND_FIXTURE.stamp
write_lines = SPEND_FIXTURE.write_lines
WORKER = "worker-dotfiles"


def fail(message):
    print(f"task-digest fixture: FAIL {message}", file=sys.stderr)
    sys.exit(1)


def check(label, condition):
    if not condition:
        fail(label)


def add_node(conn, node_id, status, route=None, tier=None, report=None, head=None, started=None, ended=None):
    conn.execute(
        "INSERT INTO nodes (id, agent, status, attempt, started_at, ended_at, report, head_sha, route, tier) "
        "VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?)",
        (node_id, WORKER, status, epoch(started) if started else None, epoch(ended) if ended else None,
         report, head, route, tier),
    )
    if started:
        conn.execute("INSERT INTO attempts (node, attempt, started_at, ended_at) VALUES (?, 1, ?, ?)",
                     (node_id, epoch(started), epoch(ended) if ended else None))


def build(home):
    """The task t5 under home/tasks, with the spend transcripts under home/.claude/projects."""
    root = os.path.join(home, "tasks", "t5")
    os.makedirs(root)
    conn = task_state.connect(root)
    conn.execute("INSERT INTO events (ts, node, kind) VALUES (?, NULL, 'reconcile')", (epoch("10:00:00"),))
    add_node(conn, "n1", "done", "continue", "T0", "reports/worker-dotfiles/n1.json", "a1a1a1a1a1", "10:00:00", "10:20:00")
    add_node(conn, "cp1", "done", "continue", ended="10:25:00")
    add_node(conn, "n2", "done", "continue", "T0", "reports/worker-dotfiles/n2.json", "b2b2b2b2b2", "10:26:00", "10:40:00")
    add_node(conn, "n3", "stopped", "stopped:needs_decision", "T2", "reports/worker-dotfiles/n3.json", "c3c3c3c3c3",
             "10:41:00", "10:50:00")
    add_node(conn, "n4", "failed", "failed:checks", None, None, None, "10:51:00", "10:55:00")
    add_node(conn, "n5", "running", started="11:01:00")
    add_node(conn, "n6", "done", "continue", "T0", "reports/worker-dotfiles/n6.json", "d4d4d4d4d4", ended="10:58:00")
    add_node(conn, "n7", "done", "continue", "T0", "reports/worker-dotfiles/n7.json", "e5e5e5e5e5", ended="10:59:00")
    add_node(conn, "cp2", "ready")
    wakes = "INSERT INTO wakes (node, tier, rule, reason, created_at, resolved_at, resolution) VALUES (?, ?, ?, ?, ?, ?, ?)"
    conn.execute(wakes, ("cp1", "opus", "checkpoint", "checkpoint cp1", epoch("10:24:00"), epoch("10:25:00"), "continue"))
    conn.execute(wakes, ("cp2", "opus", "checkpoint", "checkpoint cp2", epoch("11:02:00"), None, None))
    conn.execute(wakes, ("n3", "opus", "needs_decision", "n3 stopped", epoch("10:50:00"), None, None))
    questions = "INSERT INTO questions (qid, node, text, blocking, status, answer_path) VALUES (?, ?, ?, ?, ?, ?)"
    conn.execute(questions, ("q0", "n1", "old question", 0, "answered", "research/answers/0.md"))
    conn.execute(questions, ("q1", "n3", "Can the dispatcher retry?", 1, "open", None))
    judged = ("INSERT INTO judgements (node, attempt, model, cost_usd, judged_at, derived_route, outcome) "
              "VALUES (?, 1, 'typesafe/jev-1.14', ?, ?, ?, ?)")
    conn.execute(judged, ("n1", 0.01, epoch("10:15:00"), "continue", "continue"))
    conn.execute(judged, ("n2", 0.01, epoch("10:35:00"), "continue", "continue"))
    conn.execute(judged, ("n3", 0.02, epoch("10:45:00"), "escalate", "stopped:needs_decision"))
    conn.execute(judged, ("n4", 0.01, epoch("10:53:00"), "continue", "failed:checks"))
    conn.execute(judged, ("n5", 0.01, epoch("11:05:00"), "escalate", None))
    conn.close()
    # Every response is 1000 input and 100 output tokens: $0.003 at Sonnet's list price.
    dotfiles = os.path.join(root, "dotfiles")
    claude = os.path.join(home, ".claude", "projects")
    write_lines(os.path.join(claude, "s", "main.jsonl"), [
        assistant("o1", "claude-sonnet-5-5", stamp("10:30:00"), root, "s-orch", 1000, 100),
        assistant("o2", "claude-sonnet-5-5", stamp("10:45:00"), root, "s-orch", 1000, 100),
        assistant("o0", "claude-sonnet-5-5", stamp("10:02:00"), root, "s-orch", 1000, 100),
        assistant("w2", "claude-sonnet-5-5", stamp("10:30:00"), dotfiles, "s-w", 1000, 100),
        assistant("w3", "claude-sonnet-5-5", stamp("10:45:00"), dotfiles, "s-w", 1000, 100),
        assistant("w4", "claude-sonnet-5-5", stamp("10:46:00"), dotfiles, "s-w", 1000, 100),
        assistant("w5", "claude-sonnet-5-5", stamp("10:53:00"), dotfiles, "s-w", 1000, 100),
        assistant("w6", "claude-sonnet-5-5", stamp("11:03:00"), dotfiles, "s-w", 1000, 100),
        assistant("w7", "claude-sonnet-5-5", stamp("10:50:30"), dotfiles, "s-w", 1000, 100),
    ])
    write_lines(os.path.join(claude, "s", "subagents", "agent-a.jsonl"), [
        assistant("sa1", "claude-sonnet-5-5", stamp("10:47:00"), dotfiles, "s-w", 1000, 100, sidechain=True),
    ])
    return root


def digest(home, root, env_extra=None):
    env = dict(os.environ, HOME=home)
    env.update(env_extra or {})
    result = subprocess.run([sys.executable, "-I", str(DISPATCH), "digest", "--task-root", root],
                            capture_output=True, text=True, env=env, timeout=120)
    return result.returncode, result.stdout, result.stderr


def check_digest(home, root):
    code, out, err = digest(home, root)
    check(f"digest exits 0: {err}", code == 0)
    lines = out.splitlines()
    check("packet is at most 40 lines", len(lines) <= 40)
    text = out.replace("\n", " | ")
    check("header names the last passed checkpoint", lines[0].startswith("digest t5: after cp1 passed "))
    check("header names the waiting checkpoint", "checkpoint waiting: cp2" in lines[0])
    nodes = [line.split()[0] for line in lines if line.startswith("  ") and "route=" in line]
    check(f"nodes since cp1, in end order, without checkpoints or running ones: {nodes}",
          nodes == ["n2", "n3", "n4", "n6", "n7"])
    check("n3 line", any(line.strip().startswith("n3 stopped route=stopped:needs_decision tier=T2 "
                                                  "report=reports/worker-dotfiles/n3.json head=c3c3c3c") for line in lines))
    check("n4 line shows no tier, report or head", any(
        line.strip() == "n4 failed route=failed:checks tier=- report=- head=-" for line in lines))
    # work: n2 1 turn, n3 3 (two workers and the subagent), n4 1, n5 1 = 6 turns, $0.018. T2: 2 turns. Unattributed: w7.
    check(f"spend line: {text}", "spend: work $0.0180 (6), T1 jev $0.0500 (4), T2 orchestrator $0.0060 (2), "
          "unattributed $0.0030 (1)" in lines)
    check(f"audit: highest-spend continued node is n2: {text}", "spend n2 ($0.0030)" in text)
    picked = [line for line in lines if line.startswith("audit:")][0].split("random ")
    check(f"audit: one random node from n6 and n7: {text}", len(picked) == 2 and picked[1] in ("n6", "n7"))
    check("open wakes and questions", "open wakes: 2; open questions: 1" in lines)
    check("jev shadow agreement 3 of 4", "jev shadow agreement: 3/4 (75%)" in lines)
    again = digest(home, root)[1]
    check("the random audit pick is the same on a second run", again == out)


def check_no_checkpoint(home):
    root = os.path.join(home, "tasks", "t6")
    os.makedirs(root)
    conn = task_state.connect(root)
    add_node(conn, "m1", "done", "continue", "T0", "reports/worker-dotfiles/m1.json", "f6f6f6f6f6", ended="10:05:00")
    conn.close()
    code, out, err = digest(home, root)
    check(f"no checkpoint: exits 0: {err}", code == 0)
    lines = out.splitlines()
    check(f"no checkpoint: header: {lines[:1]}", lines[0] == "digest t6: from the task start; checkpoint waiting: none")
    check("no checkpoint: one node", "nodes (1):" in lines)
    check("no checkpoint: spend is zero", "spend: work $0.0000 (0), T1 jev $0.0000 (0), T2 orchestrator $0.0000 (0)"
          in lines)
    check("no checkpoint: audit picks the only continued node", "audit: spend m1 ($0.0000)" in lines)
    check("no checkpoint: no judged attempt", "jev shadow agreement: no judged attempt has a final outcome yet" in lines)


def check_no_state(home):
    root = os.path.join(home, "tasks", "t7")
    os.makedirs(root)
    code, out, _ = digest(home, root)
    check("no state.db: exits 0 and says so", code == 0 and out.strip() == "digest: no state.db")


def digest_hash(root):
    return hashlib.sha256(Path(root, "state.db").read_bytes()).hexdigest()


def main():
    base = tempfile.mkdtemp(prefix="task-digest-")
    try:
        home = os.path.join(base, "home")
        root = build(home)
        before = digest_hash(root)
        check_digest(home, root)
        check("digest writes nothing: state.db unchanged", digest_hash(root) == before)
        check_no_checkpoint(home)
        check_no_state(home)
        print("task-digest fixture: ok")
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    main()
