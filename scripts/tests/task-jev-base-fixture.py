#!/usr/bin/env python3
"""Offline checks for jev's diff base and fail-closed inputs (arch v2 M3d-3): the attempt's start sha, the origin/HEAD and
local main fallbacks, a stored start sha read back from state.db, and route mode escalating without a request when an
input is missing. jev is a fake ask function. Writes only in a temp folder.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from io import StringIO
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "env/.config/tmux/scripts"
BUDGET = {"prompt_k": 150, "turns": 100}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dispatch = load("task_dispatch", "task-dispatch.py")
task_jev = dispatch.task_jev
task_state = dispatch.task_state
FAVORABLE = task_jev.FAVORABLE
task_spend = load("task_spend", "task-spend.py")


def check(label, condition, detail=None):
    if not condition:
        raise AssertionError(f"{label}: {detail}")


def fake_ask(seen):
    def ask(body, *, url, shape, env, key_path, asked=None, **_):
        seen.append(body)
        answers = {qid: {"choice": FAVORABLE[qid], "confidence": 0.9} for qid in body["questions"]}
        return {"answers": answers, "latency_ms": 5, "input_tokens": 1000}
    return ask


def node(node_id, spec, after=()):
    return dispatch.task_plan.Node(id=node_id, agent="worker-dotfiles", spec=spec, after=list(after), scope=["env/x"],
                                   contracts=[], checkpoint=False, review="none", session="", budget=BUDGET, plan_hash="h")


def git(wt, *args):
    return subprocess.run(["git", "-C", str(wt), "-c", "user.name=t", "-c", "user.email=t@example.org", *args],
                          check=True, capture_output=True, text=True).stdout.strip()


def make_worktree(tmp, branch="main", origin=True):
    """Commits base (origin/main when origin), change f.py, then g.py. Returns (worktree, sha after f.py, sha after g.py)."""
    wt = tmp / "wt"
    wt.mkdir(parents=True)
    git(wt, "init", "-q", "-b", branch)
    git(wt, "commit", "-q", "--allow-empty", "-m", "base")
    if origin:
        git(wt, "update-ref", "refs/remotes/origin/main", "HEAD")
        git(wt, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    (wt / "env/x").mkdir(parents=True)
    (wt / "env/x/f.py").write_text("x = 1\n", encoding="utf-8")
    git(wt, "add", "-A")
    git(wt, "commit", "-q", "-m", "f")
    first = git(wt, "rev-parse", "HEAD")
    (wt / "env/x/g.py").write_text("y = 2\n", encoding="utf-8")
    git(wt, "add", "-A")
    git(wt, "commit", "-q", "-m", "g")
    return wt, first, git(wt, "rev-parse", "HEAD")


def make_root(tmp, wt, head, spec_text="Goal: a\n", successor=True):
    root = tmp / "task"
    (root / "specs").mkdir(parents=True)
    (root / "specs/a.md").write_text(spec_text, encoding="utf-8")
    (root / "specs/b.md").write_text("Goal: b\n", encoding="utf-8")
    (root / "AGENTS.md").write_text(f"- worker-dotfiles: agent `worker-dotfiles`, worktree `{wt}`\n", encoding="utf-8")
    report = root / "reports/worker-dotfiles/a.json"
    report.parent.mkdir(parents=True)
    report.write_text(json.dumps({
        "step": "a", "agent": "worker-dotfiles", "head_sha": head, "files_changed": ["env/x/g.py"],
        "checks": [{"cmd": "t", "exit": 0}], "risks": [], "summary": "Built the thing.", "needs_decision": None,
        "context_estimate_k": 40, "questions": [],
    }), encoding="utf-8")
    plan = {"a": node("a", "specs/a.md")}
    if successor:
        plan["b"] = node("b", "specs/b.md", after=["a"])
    return root, plan


def evaluate(root, plan, mode="route", threshold="0.8"):
    """Route-mode evaluate for step a with jev faked. Returns the exit code and the requests jev received."""
    seen = []
    env = {"PATH": os.environ.get("PATH", ""), "HOME": str(Path.home()), "TASK_JEV_MODE": mode, "TASK_JEV_THRESHOLD": threshold}
    with mock.patch.dict(os.environ, env, clear=True), \
            mock.patch.object(dispatch, "route", return_value=(0, "decided")), \
            mock.patch.object(task_jev, "ask", side_effect=fake_ask(seen)):
        code, line, _ = dispatch.evaluate(root, "worker-dotfiles", "a", ["env/x"], BUDGET, plan)
    return code, line, seen


def test_default_base(tmp):
    wt, _, _ = make_worktree(tmp / "origin")
    check("a stored start sha is the base", task_jev.default_base(wt, "abc123") == "abc123")
    check("origin/HEAD is the base without a start sha", task_jev.default_base(wt) == "origin/main")
    local, _, _ = make_worktree(tmp / "local", origin=False)
    check("local main is the base without origin/HEAD", task_jev.default_base(local) == "main")
    trunk, _, _ = make_worktree(tmp / "trunk", branch="trunk", origin=False)
    check("no base resolves: None, so the caller fails closed", task_jev.default_base(trunk) is None)


def test_start_sha_round_trip(tmp):
    wt, first, _ = make_worktree(tmp / "rt")
    root = tmp / "rt-task"
    root.mkdir()
    check("no state db: no start sha", task_state.start_sha_of(root, "a") is None)
    conn = task_state.connect(root)
    conn.execute("INSERT INTO nodes (id, agent, status, attempt) VALUES ('a', 'worker-dotfiles', 'ready', 0)")
    task_state.install(conn, "a", BUDGET)
    task_state.start(conn, "a", start_sha=first)
    check("the attempt stores its start sha", task_state.start_sha_of(root, "a") == first)
    conn.close()


def test_diff_base_in_request(tmp):
    wt, first, last = make_worktree(tmp / "diff")
    root, plan = make_root(tmp / "diff", wt, last)
    conn = task_state.connect(root)
    conn.execute("INSERT INTO nodes (id, agent, status, attempt) VALUES ('a', 'worker-dotfiles', 'ready', 0)")
    task_state.install(conn, "a", BUDGET)
    task_state.start(conn, "a", start_sha=first)
    conn.close()
    code, _, seen = evaluate(root, plan)
    body = json.dumps(seen)
    check("the request diffs from the start sha", "g.py" in body and "f.py" not in body, body[:200])
    check("the request is sent", code == 0 and len(seen) >= 1, code)


def test_fail_closed(tmp):
    wt, _, last = make_worktree(tmp / "fc")
    root, plan = make_root(tmp / "empty", wt, last, spec_text="")
    code, line, seen = evaluate(root, plan)
    check("an empty spec escalates without a request", code == dispatch.JEV_ESCALATE and seen == [], (code, line))
    root, plan = make_root(tmp / "succ", wt, last)
    (root / "specs/b.md").unlink()
    code, line, seen = evaluate(root, plan)
    check("an expected successor with no spec escalates", code == dispatch.JEV_ESCALATE and seen == [], (code, line))
    trunk, _, tlast = make_worktree(tmp / "trunk", branch="trunk", origin=False)
    root, plan = make_root(tmp / "nobase", trunk, tlast)
    code, line, seen = evaluate(root, plan)
    check("no diff base escalates", code == dispatch.JEV_ESCALATE and seen == [] and "diff base unknown" in line, line)
    root, plan = make_root(tmp / "badsha", wt, last)
    conn = task_state.connect(root)
    conn.execute("INSERT INTO nodes (id, agent, status, attempt) VALUES ('a', 'worker-dotfiles', 'ready', 0)")
    task_state.install(conn, "a", BUDGET)
    task_state.start(conn, "a", start_sha="0" * 40)
    conn.close()
    code, line, seen = evaluate(root, plan)
    check("an unavailable diffstat escalates", code == dispatch.JEV_ESCALATE and seen == [] and "diffstat" in line, line)


def test_price_fallback(tmp):
    """A TASK_JEV_MODEL override with no price row is priced as the fallback model, with a stderr note."""
    task = tmp / "tasks/price"
    task.mkdir(parents=True)
    conn = task_state.connect(task)
    conn.execute("INSERT INTO nodes (id, agent, status, attempt) VALUES ('a', 'worker-dotfiles', 'ready', 0)")
    task_state.install(conn, "a", BUDGET)
    task_state.record_judgement(conn, "a", 1, {"mode": "shadow", "model": "acme/jev-override", "request_hash": "h",
                                               "answers": {}, "error": None, "latency_ms": 5, "input_tokens": 1000,
                                               "cost_usd": None, "derived_route": "continue"})
    conn.close()
    stderr = StringIO()
    with mock.patch.object(sys, "stderr", stderr):
        rows = task_spend.judgement_responses(str(tmp / "tasks"))
    check("the override is priced as the fallback", len(rows) == 1 and rows[0]["price_model"] == task_spend.JUDGE_FALLBACK_MODEL, rows)
    check("the override is noted once on stderr", "acme/jev-override has no price" in stderr.getvalue(), stderr.getvalue())


def main():
    with tempfile.TemporaryDirectory(prefix="jev-base-fixture-") as folder:
        tmp = Path(folder)
        test_default_base(tmp / "base")
        test_start_sha_round_trip(tmp / "round")
        test_diff_base_in_request(tmp / "request")
        test_fail_closed(tmp / "closed")
        test_price_fallback(tmp / "price")
    print("task-jev-base fixture: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
