#!/usr/bin/env python3
"""Offline checks for task_plan.py (C5) and task_state.py (C6), and the plan CLI of task-dispatch.py.

Each scenario builds a task root in a temporary folder: AGENTS.md with worker-dotfiles under Repo modes,
plan/dag.toml and specs/. Covers plan validation, defaults, ready() with parallel agents and one node per
agent, reconcile (add, cancel, revive, edited and removed running nodes, idempotence), a crash mid-transition
leaving no partial rows, stale-report rejection, one running node per agent, and the CLI exit codes.
Writes only inside a temporary folder.
"""
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "env/.config/tmux/scripts"
DISPATCH = SCRIPTS / "task-dispatch.py"
sys.path.insert(0, str(SCRIPTS))

import task_plan  # noqa: E402
import task_state  # noqa: E402

AGENTS_MD = """# t

## Repo modes

### Worker repos
- **dotfiles** — agent `worker-dotfiles`.
- **other** — agent `worker-other`.

## Agents
| name | role |
|---|---|
| orchestrator | orchestrator |
"""

FAILURES = []


def check(label, condition, detail=None):
    if condition:
        print(f"ok   {label}")
    else:
        print(f"FAIL {label} {'' if detail is None else detail}")
        FAILURES.append(label)


def make_root(files):
    """A task root with AGENTS.md, plus the given files (path -> text). A plan goes in as plan/dag.toml."""
    root = Path(tempfile.mkdtemp(prefix="plan-fixture-"))
    (root / "AGENTS.md").write_text(AGENTS_MD, encoding="utf-8")
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return root


def node(node_id, agent="worker-dotfiles", extra=""):
    scope = "" if agent.startswith("orchestrator") or agent == "researcher" else 'scope = ["env/**"]\n'
    return f'[[node]]\nid = "{node_id}"\nagent = "{agent}"\nspec = "specs/{node_id}.md"\n{scope}{extra}\n'


def specs(*ids):
    return {f"specs/{i}.md": f"# {i}\n" for i in ids}


def errors_of(root):
    try:
        task_plan.load_plan(root)
    except task_plan.PlanError as error:
        return error.errors
    return []


def scenario_valid_and_defaults():
    plan = (
        '[defaults]\nsession = "continue"\nbudget = { turns = 40 }\n\n'
        + node("a")
        + node("r", "researcher", 'budget = { prompt_k = 50 }\n')
        + '[[node]]\nid = "m1-review"\nagent = "orchestrator"\nafter = ["a", "r", "q:7"]\ncheckpoint = true\n'
    )
    root = make_root({"plan/dag.toml": plan, **specs("a", "r")})
    nodes = task_plan.load_plan(root)
    check("valid plan loads its nodes in file order", list(nodes) == ["a", "r", "m1-review"], list(nodes))
    a, r, review = nodes["a"], nodes["r"], nodes["m1-review"]
    check("[defaults] session applies to nodes", a.session == "continue" and r.session == "continue")
    check("budget merges node over defaults", a.budget == {"turns": 40, "prompt_k": 90}, a.budget)
    check("node budget overrides one key", r.budget == {"turns": 40, "prompt_k": 50}, r.budget)
    check("review falls back to the built-in default", a.review == "judge")
    check("checkpoint node needs no spec", review.spec is None and review.checkpoint is True)
    check("after keeps q: deps", review.after == ["a", "r", "q:7"], review.after)
    again = task_plan.load_plan(root)
    check("plan_hash is stable", again["a"].plan_hash == a.plan_hash)
    (root / "specs/a.md").write_text("# a, edited\n", encoding="utf-8")
    check("editing a spec changes its plan_hash", task_plan.load_plan(root)["a"].plan_hash != a.plan_hash)


def scenario_validation_errors():
    cycle = make_root({
        "plan/dag.toml": node("a", extra='after = ["b"]\n') + node("b", extra='after = ["a"]\n'),
        **specs("a", "b"),
    })
    check("cycle is reported with its path", "cycle: a -> b -> a" in errors_of(cycle), errors_of(cycle))
    selfloop = make_root({"plan/dag.toml": node("a", extra='after = ["a"]\n'), **specs("a")})
    check("self dependency is a cycle", "cycle: a -> a" in errors_of(selfloop), errors_of(selfloop))

    agent = make_root({"plan/dag.toml": node("a", agent="worker-nope"), **specs("a")})
    check("unknown agent is named", any("unknown agent 'worker-nope'" in e for e in errors_of(agent)), errors_of(agent))

    missing = make_root({"plan/dag.toml": node("a")})
    check("missing spec is reported", any("spec file 'specs/a.md' not found" in e for e in errors_of(missing)), errors_of(missing))

    dupes = make_root({"plan/dag.toml": node("a") + node("a"), **specs("a")})
    check("duplicate id is reported", any("node a: duplicate id" in e for e in errors_of(dupes)), errors_of(dupes))

    unknown_dep = make_root({"plan/dag.toml": node("a", extra='after = ["zzz"]\n'), **specs("a")})
    check("unknown after is reported", any("after zzz is neither" in e for e in errors_of(unknown_dep)), errors_of(unknown_dep))

    bad_q = make_root({"plan/dag.toml": node("a", extra='after = ["q:"]\n'), **specs("a")})
    check("q: without a question id is reported", any("after q: is neither" in e for e in errors_of(bad_q)), errors_of(bad_q))

    no_scope = make_root({"plan/dag.toml": '[[node]]\nid = "a"\nagent = "worker-dotfiles"\nspec = "specs/a.md"\n', **specs("a")})
    check("worker node without scope is reported", any("needs scope globs" in e for e in errors_of(no_scope)), errors_of(no_scope))

    typo = make_root({"plan/dag.toml": node("a", extra="aftr = []\n"), **specs("a")})
    check("unknown node key is reported", any("unknown key aftr" in e for e in errors_of(typo)), errors_of(typo))

    broken = make_root({"plan/dag.toml": "[[node\n"})
    check("TOML syntax error is reported", errors_of(broken) and errors_of(broken)[0].startswith("plan/dag.toml:"), errors_of(broken))


def scenario_path_and_type_errors():
    typed = make_root({"plan/dag.toml": '[[node]]\nid = "a"\nagent = ["worker-dotfiles"]\nspec = "specs/a.md"\nscope = ["env/**"]\n', **specs("a")})
    check("a non-string agent is reported, not a crash", errors_of(typed) == ["node a: agent must be a name"], errors_of(typed))
    outside = Path(tempfile.mkdtemp(prefix="plan-outside-")) / "outside.md"
    outside.write_text("# outside\n", encoding="utf-8")
    base = '[[node]]\nid = "a"\nagent = "worker-dotfiles"\nscope = ["env/**"]\n'
    absolute = make_root({"plan/dag.toml": base + f'spec = "{outside}"\n', **specs("a")})
    check("an absolute spec is rejected", any("must be a relative path inside the task root" in e for e in errors_of(absolute)), errors_of(absolute))
    up = make_root({"plan/dag.toml": base + f'spec = "../{outside.name}"\n'})
    (up.parent / outside.name).write_text("# outside\n", encoding="utf-8")
    check("a spec with .. is rejected even when the file exists", any("must be a relative path" in e for e in errors_of(up)), errors_of(up))
    link = make_root({"plan/dag.toml": base + 'spec = "specs/link.md"\n', **specs("a")})
    (link / "specs/a.md").unlink()
    (link / "specs/link.md").symlink_to(outside)
    check("a spec symlink outside the root is rejected", any("must be a relative path" in e for e in errors_of(link)), errors_of(link))
    dotdot_scope = make_root({"plan/dag.toml": base.replace('"env/**"', '"env/../../x"') + 'spec = "specs/a.md"\n', **specs("a")})
    check("a scope glob with .. is reported", errors_of(dotdot_scope) == ["node a: scope env/../../x must be relative, without .."], errors_of(dotdot_scope))
    absolute_scope = make_root({"plan/dag.toml": base.replace('"env/**"', '"/etc/**"') + 'spec = "specs/a.md"\n', **specs("a")})
    check("an absolute scope glob is reported", any("scope /etc/** must be relative" in e for e in errors_of(absolute_scope)), errors_of(absolute_scope))
    bad_id = make_root({"plan/dag.toml": node("bad id") + node("b", extra='after = ["bad id"]\n'), **specs("b")})
    check("a dependent of an invalid id adds no cascade error", errors_of(bad_id) == ["node #1: id must be a name such as web-11"], errors_of(bad_id))


def scenario_ready():
    plan = (
        node("a") + node("b") + node("r", "researcher")
        + '[[node]]\nid = "c"\nagent = "orchestrator"\nafter = ["a", "q:7"]\ncheckpoint = true\n'
    )
    root = make_root({"plan/dag.toml": plan, **specs("a", "b", "r")})
    nodes = task_plan.load_plan(root)

    def state(rows, answered=()):
        return {"nodes": {k: {"agent": v[0], "status": v[1], "route": v[2]} for k, v in rows.items()}, "answered": set(answered)}

    pending = {"a": ("worker-dotfiles", "pending", None), "b": ("worker-dotfiles", "pending", None),
               "r": ("researcher", "pending", None), "c": ("orchestrator", "pending", None)}
    check("ready: one per agent, dependent node waits", task_plan.ready(nodes, state(pending)) == ["a", "r"],
          task_plan.ready(nodes, state(pending)))

    running_a = {**pending, "a": ("worker-dotfiles", "running", None)}
    check("ready: an agent with a running node gets nothing; others run in parallel",
          task_plan.ready(nodes, state(running_a)) == ["r"], task_plan.ready(nodes, state(running_a)))

    done_a = {**pending, "a": ("worker-dotfiles", "done", "continue"), "r": ("researcher", "running", None)}
    check("ready: a continue route releases dependents and the agent's next node",
          task_plan.ready(nodes, state(done_a)) == ["b"], task_plan.ready(nodes, state(done_a)))

    checkpoint_ready = task_plan.ready(nodes, state({**done_a, "a": ("worker-dotfiles", "done", "continue")}, ["7"]))
    check("ready: an answered q: releases the checkpoint", checkpoint_ready == ["b", "c"], checkpoint_ready)

    stopped = {**pending, "a": ("worker-dotfiles", "stopped", "stopped:needs_decision")}
    check("ready: a stopped dep never releases its dependents", "c" not in task_plan.ready(nodes, state(stopped)))


def scenario_edits():
    root = make_root({"plan/dag.toml": node("a") + node("b") + node("c"), **specs("a", "b", "c")})
    conn = task_state.connect(root)
    try:
        task_state.reconcile(conn, task_plan.load_plan(root))
        task_state.install(conn, "b", {"turns": 60, "prompt_k": 90})
        task_state.install(conn, "a", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "a", prompt_at=1_000_000.0)
        task_state.settle(conn, "a", "r.json", 1_000_005.0)
        task_state.route(conn, "a", "continue")
        (root / "specs/a.md").write_text("# a, edited after done\n", encoding="utf-8")
        (root / "specs/b.md").write_text("# b, edited while ready\n", encoding="utf-8")
        counts = task_state.reconcile(conn, task_plan.load_plan(root))
        check("edits to ready and done nodes are counted", counts == {"added": 0, "edited": 2, "cancelled": 0, "woken": 0}, counts)
        rows = task_state.snapshot(conn)["nodes"]
        check("edited ready node goes back to pending", rows["b"]["status"] == "pending", rows["b"]["status"])
        check("edited done node keeps its status", rows["a"]["status"] == "done", rows["a"]["status"])
        details = [row[0] for row in conn.execute("SELECT detail FROM events WHERE kind = 'reconcile' AND node IS NOT NULL")]
        check("the ready reset is logged", any("reset to pending" in d for d in details), details)
        check("the done edit is logged", any(d.startswith("edited while done") for d in details), details)
        check("an edited ready node installs again", task_state.install(conn, "b", {"turns": 60, "prompt_k": 90}) == 2)
        again = task_state.reconcile(conn, task_plan.load_plan(root))
        check("second reconcile sees no edits", again["edited"] == 0, again)
    finally:
        conn.close()


def scenario_agent_change():
    root = make_root({"plan/dag.toml": node("a"), **specs("a")})
    conn = task_state.connect(root)
    try:
        task_state.reconcile(conn, task_plan.load_plan(root))
        task_state.install(conn, "a", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "a", prompt_at=1_000_000.0)
        (root / "plan/dag.toml").write_text(node("a", "worker-other"), encoding="utf-8")
        counts = task_state.reconcile(conn, task_plan.load_plan(root))
        check("agent change on a running node raises one wake", counts["woken"] == 1, counts)
        detail = conn.execute("SELECT reason FROM wakes WHERE node = 'a'").fetchone()[0]
        check("the wake records the agent change", "worker-dotfiles -> worker-other" in detail, detail)
        check("the running node keeps its old agent", task_state.snapshot(conn)["nodes"]["a"]["agent"] == "worker-dotfiles")
        task_state.settle(conn, "a", "r.json", 1_000_005.0)
        task_state.route(conn, "a", "stopped:needs_decision", reason="agent change")
        task_state.reconcile(conn, task_plan.load_plan(root))
        check("the new agent applies once the node stops", task_state.snapshot(conn)["nodes"]["a"]["agent"] == "worker-other")
    finally:
        conn.close()


def scenario_route_needs_report():
    root = make_root({"plan/dag.toml": node("a") + node("k", extra="checkpoint = true\n"), **specs("a", "k")})
    conn = task_state.connect(root)
    try:
        task_state.reconcile(conn, task_plan.load_plan(root))
        task_state.install(conn, "a", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "a", prompt_at=1_000_000.0)
        check("continue without an accepted report is refused", _refused(lambda: task_state.route(conn, "a", "continue")))
        check("the refused route leaves the node running", task_state.snapshot(conn)["nodes"]["a"]["status"] == "running")
        task_state.settle(conn, "a", "r.json", 1_000_005.0)
        task_state.route(conn, "a", "continue")
        task_state.install(conn, "k", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "k", prompt_at=1_000_000.0)
        check("checkpoint without an accepted report is refused", _refused(lambda: task_state.route(conn, "k", "checkpoint")))
        task_state.settle(conn, "k", "r.json", 1_000_005.0)
        task_state.route(conn, "k", "checkpoint")
        check("checkpoint with a report routes", task_state.snapshot(conn)["nodes"]["k"]["route"] == "checkpoint")
    finally:
        conn.close()


def scenario_checkpoint():
    plan = node("a") + '[[node]]\nid = "c"\nagent = "orchestrator"\nafter = ["a"]\ncheckpoint = true\n' + node("b", extra='after = ["c"]\n')
    root = make_root({"plan/dag.toml": plan, **specs("a", "b")})
    nodes = task_plan.load_plan(root)
    conn = task_state.connect(root)
    try:
        task_state.reconcile(conn, nodes)
        task_state.install(conn, "a", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "a", prompt_at=1_000_000.0)
        task_state.settle(conn, "a", "r.json", 1_000_005.0)
        task_state.route(conn, "a", "continue")
        check("checkpoint is ready once its dep continues", task_plan.ready(nodes, task_state.snapshot(conn)) == ["c"])
        task_state.install(conn, "c", {"turns": 60, "prompt_k": 90})
        wake = task_state.wake(conn, "c", "opus", "checkpoint", "A is in; continue to B?")
        check("b waits while the checkpoint is open", "b" not in task_plan.ready(nodes, task_state.snapshot(conn)))
        task_state.resolve(conn, wake, "continue")
        row = task_state.snapshot(conn)["nodes"]["c"]
        check("resolve(continue) passes the checkpoint", row["status"] == "done" and row["route"] == "continue", row)
        check("b is ready only after the resolve", task_plan.ready(nodes, task_state.snapshot(conn)) == ["b"])
    finally:
        conn.close()


def scenario_read_only_connect():
    root = make_root({"plan/dag.toml": node("a"), **specs("a")})
    task_state.connect(root).close()
    holder = sqlite3.connect(root / "state.db", isolation_level=None)
    holder.execute("BEGIN IMMEDIATE")
    started = time.time()
    try:
        task_state.connect(root).close()
        opened = True
    except sqlite3.Error:
        opened = False
    finally:
        holder.execute("ROLLBACK")
        holder.close()
    check("a read-only connect does not wait for the write lock", opened and time.time() - started < 5)


def scenario_commit_rollback():
    root = make_root({"plan/dag.toml": node("a"), **specs("a")})
    conn = task_state.connect(root)
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        conn.execute("CREATE TABLE child (pid INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)")
        try:
            with task_state.transaction(conn):
                conn.execute("INSERT INTO child (pid) VALUES (99)")
            failed = False
        except sqlite3.IntegrityError:
            failed = True
        check("a failed COMMIT raises", failed)
        check("a failed COMMIT leaves no open transaction", not conn.in_transaction)
        with task_state.transaction(conn):
            conn.execute("INSERT INTO parent (id) VALUES (1)")
        check("the next transaction still commits", conn.execute("SELECT COUNT(*) FROM parent").fetchone()[0] == 1)
    finally:
        conn.close()


def scenario_reconcile():
    plan = node("a") + node("b") + node("r", "researcher")
    root = make_root({"plan/dag.toml": plan, **specs("a", "b", "r")})
    conn = task_state.connect(root)
    try:
        nodes = task_plan.load_plan(root)
        check("reconcile adds new nodes as pending", task_state.reconcile(conn, nodes)["added"] == 3)
        check("reconcile is idempotent", task_state.reconcile(conn, nodes) == {"added": 0, "edited": 0, "cancelled": 0, "woken": 0})

        task_state.install(conn, "a", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "a", session_id="s1", prompt_at=time.time())
        (root / "specs/a.md").write_text("# a, changed while running\n", encoding="utf-8")
        counts = task_state.reconcile(conn, task_plan.load_plan(root))
        check("edited running node raises one wake", counts == {"added": 0, "edited": 1, "cancelled": 0, "woken": 1}, counts)
        check("edited running node keeps running", task_state.snapshot(conn)["nodes"]["a"]["status"] == "running")
        again = task_state.reconcile(conn, task_plan.load_plan(root))
        check("second reconcile raises no second wake", again["woken"] == 0 and again["edited"] == 0, again)
        wake_id = conn.execute("SELECT id FROM wakes WHERE node = 'a'").fetchone()[0]
        task_state.resolve(conn, wake_id, "accepted the change")
        check("resolve closes the wake", conn.execute("SELECT resolved_at FROM wakes WHERE id = ?", (wake_id,)).fetchone()[0])

        (root / "plan/dag.toml").write_text(node("a") + node("r", "researcher"), encoding="utf-8")
        counts = task_state.reconcile(conn, task_plan.load_plan(root))
        check("removed pending node is cancelled", counts["cancelled"] == 1, counts)
        check("removed pending node has status cancelled", task_state.snapshot(conn)["nodes"]["b"]["status"] == "cancelled")

        task_state.install(conn, "r", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "r", session_id="s2")
        (root / "plan/dag.toml").write_text(node("a"), encoding="utf-8")
        counts = task_state.reconcile(conn, task_plan.load_plan(root))
        check("removed running node raises a wake and keeps running",
              counts["woken"] == 1 and task_state.snapshot(conn)["nodes"]["r"]["status"] == "running", counts)
        wake_r = conn.execute("SELECT id FROM wakes WHERE node = 'r'").fetchone()[0]
        task_state.resolve(conn, wake_r, "keep it running")
        again = task_state.reconcile(conn, task_plan.load_plan(root))
        check("a resolved removed-running wake does not repeat", again["woken"] == 0, again)

        (root / "plan/dag.toml").write_text(node("a") + node("b"), encoding="utf-8")
        counts = task_state.reconcile(conn, task_plan.load_plan(root))
        check("a cancelled node that returns to the plan is pending again", counts["added"] == 1 and counts["woken"] == 0, counts)
        check("revived node is pending", task_state.snapshot(conn)["nodes"]["b"]["status"] == "pending")
        events = [row[0] for row in conn.execute("SELECT kind FROM events WHERE kind = 'reconcile' AND node IS NULL")]
        check("every reconcile is logged", len(events) == 8, len(events))
    finally:
        conn.close()


def scenario_crash_safety():
    root = make_root({"plan/dag.toml": node("a") + node("b"), **specs("a", "b")})
    conn = task_state.connect(root)
    real_event = task_state._event
    calls = []

    def crash_before_logging(conn_, node_id, kind, detail):
        # reconcile writes its node rows first and logs its event last, so this crashes after the inserts
        calls.append(kind)
        if len(calls) == 1:
            raise RuntimeError("simulated crash")
        real_event(conn_, node_id, kind, detail)

    task_state._event = crash_before_logging
    try:
        task_state.reconcile(conn, task_plan.load_plan(root))
        check("crash mid-transition raises", False)
    except RuntimeError:
        check("crash mid-transition raises", True)
    finally:
        task_state._event = real_event
    nodes = conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    events = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    check("crash leaves no partial node rows", nodes == 0, nodes)
    check("crash leaves no partial events", events == 0, events)
    conn.close()


def scenario_transitions():
    root = make_root({"plan/dag.toml": node("a") + node("b"), **specs("a", "b")})
    conn = task_state.connect(root)
    try:
        task_state.reconcile(conn, task_plan.load_plan(root))
        prompt_at = 1_000_000.0
        task_state.install(conn, "a", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "a", session_id="s1", prompt_at=prompt_at)
        check("stale report (written before the prompt) is rejected",
              task_state.settle(conn, "a", "reports/worker-dotfiles/a.json", prompt_at - 5) is False)
        check("a report written at the prompt instant is rejected", task_state.settle(conn, "a", "x.json", prompt_at) is False)
        row = task_state.snapshot(conn)["nodes"]["a"]
        check("rejected report leaves the node running with no report", row["status"] == "running" and row["report"] is None)
        check("fresh report is accepted", task_state.settle(conn, "a", "reports/worker-dotfiles/a.json", prompt_at + 5, "abc1234") is True)

        task_state.route(conn, "a", "continue", reason="gates pass")
        check("continue route finishes the node", task_state.snapshot(conn)["nodes"]["a"]["status"] == "done")

        task_state.install(conn, "b", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "b", session_id="s2", prompt_at=prompt_at)
        task_state.route(conn, "b", "stopped:needs_decision", reason="which API")
        check("stopped route stops the node", task_state.snapshot(conn)["nodes"]["b"]["status"] == "stopped")
        try:
            task_state.route(conn, "b", "weird")
            check("unknown route is refused", False)
        except task_state.TransitionError:
            check("unknown route is refused", True)

        check("install refuses a finished node", _refused(lambda: task_state.install(conn, "a", {"turns": 1, "prompt_k": 1})))
    finally:
        conn.close()


def scenario_one_running_per_agent():
    root = make_root({"plan/dag.toml": node("a") + node("b"), **specs("a", "b")})
    conn = task_state.connect(root)
    try:
        task_state.reconcile(conn, task_plan.load_plan(root))
        task_state.install(conn, "a", {"turns": 60, "prompt_k": 90})
        task_state.start(conn, "a")
        task_state.install(conn, "b", {"turns": 60, "prompt_k": 90})
        check("start refuses a second running node for one agent", _refused(lambda: task_state.start(conn, "b")))
        check("refused start leaves the node ready", task_state.snapshot(conn)["nodes"]["b"]["status"] == "ready")
    finally:
        conn.close()


def scenario_schema():
    root = make_root({"plan/dag.toml": node("a"), **specs("a")})
    for _ in range(2):
        conn = task_state.connect(root)
        conn.close()
    conn = task_state.connect(root)
    versions = [row[0] for row in conn.execute("SELECT version FROM schema_version")]
    tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    conn.close()
    check("migrations apply once, in order", versions == [1, 2], versions)
    check("schema has the §3 tables", {"nodes", "attempts", "events", "wakes", "judgements", "questions"} <= tables, tables)
    check("state.db is in WAL mode", mode == "wal", mode)


def _refused(action):
    try:
        action()
    except task_state.TransitionError:
        return True
    return False


def cli(args, root):
    return subprocess.run([sys.executable, str(DISPATCH), "plan", *args, "--task-root", str(root)],
                          capture_output=True, text=True, timeout=60)


def scenario_cli():
    good = make_root({"plan/dag.toml": node("a") + node("b"), **specs("a", "b")})
    result = cli(["check"], good)
    check("plan check prints ok N nodes and exits 0", result.returncode == 0 and result.stdout.strip() == "ok 2 nodes", result)
    result = cli(["reconcile"], good)
    check("plan reconcile prints counts", result.returncode == 0 and result.stdout.startswith("reconcile: added 2"), result)
    bad = make_root({"plan/dag.toml": node("a", extra='after = ["b"]\n') + node("b", extra='after = ["a"]\n'), **specs("a", "b")})
    result = cli(["check"], bad)
    check("invalid plan exits 2 with one line per error", result.returncode == 2 and result.stdout.strip() == "cycle: a -> b -> a", result)
    result = cli(["reconcile"], bad)
    check("invalid plan does not touch state.db", result.returncode == 2 and not (bad / "state.db").exists(), result)
    newer = make_root({"plan/dag.toml": node("a"), **specs("a")})
    task_state.connect(newer).close()
    raw = sqlite3.connect(newer / "state.db")
    raw.execute("UPDATE schema_version SET version = 99")
    raw.commit()
    raw.close()
    result = cli(["reconcile"], newer)
    check("a state.db error is one line and exits 22", result.returncode == 22 and result.stdout.startswith("state.db: ")
          and result.stdout.count("\n") == 1, result)


def main():
    scenario_valid_and_defaults()
    scenario_validation_errors()
    scenario_ready()
    scenario_reconcile()
    scenario_crash_safety()
    scenario_transitions()
    scenario_one_running_per_agent()
    scenario_schema()
    scenario_cli()
    scenario_path_and_type_errors()
    scenario_route_needs_report()
    scenario_checkpoint()
    scenario_edits()
    scenario_agent_change()
    scenario_read_only_connect()
    scenario_commit_rollback()
    if FAILURES:
        print(f"FAILED: {', '.join(FAILURES)}")
        return 1
    print("task-plan fixture: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
