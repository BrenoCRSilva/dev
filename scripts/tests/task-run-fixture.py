#!/usr/bin/env python3
"""Offline checks for the dispatcher daemon and its commands (arch v2 M2, C7).

Runs the real task-dispatch.py run|status|wake-wait|wakes|resolve against the v1 fixture's fake herdr and its
decision mock (imported from task-dispatch-fixture.py, so no network and no key). Covers: a 4-node DAG across two
agents with parallel starts, a checkpoint wake, resolve continue releasing the successor; a stopped node, a retry
as a new attempt, and dispatch.lock contention; a stale report rejected; SIGTERM mid-turn leaving a consistent
state that a restarted daemon finishes. Writes only inside a temporary folder.
"""
import importlib.util
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DISPATCH = HERE.parents[1] / "env/.config/tmux/scripts/task-dispatch.py"
WORKER, WEB = "worker-dotfiles", "worker-web"
SCOPE = "env/.config/tmux/scripts/**"

v1_spec = importlib.util.spec_from_file_location("v1", HERE / "task-dispatch-fixture.py")
assert v1_spec is not None and v1_spec.loader is not None
v1 = importlib.util.module_from_spec(v1_spec)
v1_spec.loader.exec_module(v1)

AGENTS_MD = f"""# t

## Repo modes

### Worker repos
- **dotfiles** — agent `{WORKER}`.
- **web** — agent `{WEB}`.
"""

FAILURES = []


def check(label, condition, detail=""):
    if condition:
        print(f"ok   {label}")
    else:
        FAILURES.append(label)
        print(f"FAILED: {label} {detail}")


def plan_root(tmp, name, nodes):
    """A task root with AGENTS.md, plan/dag.toml, specs and the fake herdr from the v1 scenario."""
    root, fake, env = v1.scenario(tmp, name)
    (root / "AGENTS.md").write_text(AGENTS_MD, encoding="utf-8")
    (root / "plan").mkdir(exist_ok=True)
    (root / "specs").mkdir(exist_ok=True)
    text = "[defaults]\nbudget = { turns = 60, prompt_k = 90 }\n"
    for node_id, agent, after, checkpoint in nodes:
        (root / "specs" / f"{node_id}.md").write_text(f"# {node_id}\n", encoding="utf-8")
        text += f'\n[[node]]\nid = "{node_id}"\nagent = "{agent}"\nspec = "specs/{node_id}.md"\nscope = ["{SCOPE}"]\n'
        if after:
            text += "after = [" + ", ".join(f'"{dep}"' for dep in after) + "]\n"
        if checkpoint:
            text += "checkpoint = true\n"
    (root / "plan" / "dag.toml").write_text(text, encoding="utf-8")
    return root, fake, env


def turn_for(root, step, agent=WORKER, work=0.5, needs=None, report=True):
    body = v1.turn(root, step, work=work, agent=agent)
    if needs and body["report"]:
        body["report"]["needs_decision"] = needs
    if not report:
        body["report"] = None
    return body


def cli(env, root, *args, timeout=60):
    return subprocess.run([sys.executable, str(DISPATCH), *args, "--task-root", str(root)], capture_output=True, text=True, env=env, timeout=timeout)


def daemon(env, root):
    return subprocess.Popen([sys.executable, str(DISPATCH), "run", "--task-root", str(root)], env=env, stdout=subprocess.PIPE, text=True)


def stop(proc):
    proc.send_signal(signal.SIGTERM)
    return proc.communicate(timeout=30)[0]


def wait_for(predicate, seconds=40):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.2)
    return False


def status(env, root):
    return cli(env, root, "status").stdout


def db(root, sql, args=()):
    conn = sqlite3.connect(root / "state.db")
    try:
        return conn.execute(sql, args).fetchall()
    finally:
        conn.close()


def scenario_dag(tmp):
    root, fake, env = plan_root(tmp, "dag", [
        ("n1", WORKER, [], False), ("n2", WEB, [], False),
        ("n3", "orchestrator", ["n1", "n2"], True), ("n4", WORKER, ["n3"], False),
    ])
    v1.set_agent(fake, WORKER, [turn_for(root, "n1", work=2.0), turn_for(root, "n4")])
    v1.set_agent(fake, WEB, [turn_for(root, "n2", agent=WEB, work=2.0)])
    proc = daemon(env, root)
    both = wait_for(lambda: "worker-dotfiles: running n1" in status(env, root) and "worker-web: running n2" in status(env, root))
    check("dag: n1 and n2 run in parallel", both, status(env, root))
    woke = cli(env, root, "wake-wait", timeout=60).stdout
    check("dag: checkpoint wake raised for n3", " opus n3 checkpoint: " in woke, woke)
    wake_id = woke.split()[1]
    check("dag: n4 waits for the checkpoint", not db(root, "SELECT 1 FROM attempts WHERE node = 'n4'"))
    cli(env, root, "resolve", wake_id, "continue")
    done = wait_for(lambda: "worker-dotfiles: idle; done 2" in status(env, root))
    check("dag: resolve continue releases n4", done, status(env, root))
    check("dag: checkpoint routed continue", db(root, "SELECT status, route FROM nodes WHERE id = 'n3'") == [("done", "continue")])
    out = stop(proc)
    check("dag: SIGTERM stops the daemon cleanly", "dispatcher stopped" in out and not (root / "dispatch.lock").exists(), out)


def scenario_retry(tmp):
    root, fake, env = plan_root(tmp, "retry", [("r1", WORKER, [], False)])
    v1.set_agent(fake, WORKER, [turn_for(root, "r1", needs="which schema?"), turn_for(root, "r1")])
    proc = daemon(env, root)
    woke = cli(env, root, "wake-wait", timeout=60).stdout
    check("retry: needs_decision stops the node with a wake", woke.startswith("wake ") and " r1 needs_decision: " in woke, woke)
    held = cli(env, root, "run")
    check("retry: a second run is refused while the lock is held", held.returncode == 23 and "held by pid" in held.stdout, held.stdout.strip())
    wake_id = woke.split()[1]
    cli(env, root, "resolve", wake_id, "retry")
    done = wait_for(lambda: "worker-dotfiles: idle; done 1" in status(env, root))
    check("retry: the retried node finishes", done, status(env, root))
    check("retry: a second attempt ran", db(root, "SELECT attempt FROM nodes WHERE id = 'r1'") == [(2,)])
    stop(proc)


def scenario_stale(tmp):
    root, fake, env = plan_root(tmp, "stale", [("s1", WORKER, [], False)])
    report = root / "reports" / WORKER / "s1.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(v1.report("s1")), encoding="utf-8")
    os.utime(report, (time.time() - 3600, time.time() - 3600))
    v1.set_agent(fake, WORKER, [turn_for(root, "s1", report=False)])
    proc = daemon(env, root)
    woke = cli(env, root, "wake-wait", timeout=60).stdout
    check("stale: a report older than the prompt is rejected", " stale_report: " in woke, woke)
    stop(proc)


def scenario_pause(tmp):
    root, fake, env = plan_root(tmp, "pause", [("p1", WORKER, [], False)])
    v1.set_agent(fake, WORKER, [turn_for(root, "p1")])
    cli(env, root, "pause", WORKER)
    proc = daemon(env, root)
    time.sleep(3)
    check("pause: a paused agent gets no install", not db(root, "SELECT 1 FROM attempts WHERE node = 'p1'") and "[paused]" in status(env, root), status(env, root))
    cli(env, root, "resume", WORKER)
    done = wait_for(lambda: "worker-dotfiles: idle; done 1" in status(env, root))
    check("pause: resume lets the node run", done, status(env, root))
    stop(proc)


def scenario_sigterm(tmp):
    root, fake, env = plan_root(tmp, "sigterm", [("m1", WORKER, [], False)])
    v1.set_agent(fake, WORKER, [turn_for(root, "m1", work=4.0)])
    proc = daemon(env, root)
    running = wait_for(lambda: "worker-dotfiles: running m1" in status(env, root))
    check("sigterm: m1 is running", running, status(env, root))
    stop(proc)
    left = db(root, "SELECT status FROM nodes WHERE id = 'm1'")
    check("sigterm: state is consistent after SIGTERM (m1 running, attempt recorded)", left == [("running",)] and db(root, "SELECT prompt_at FROM attempts WHERE node = 'm1'")[0][0], left)
    again = daemon(env, root)
    done = wait_for(lambda: "worker-dotfiles: idle; done 1" in status(env, root))
    check("sigterm: a restarted daemon finishes the running node", done, status(env, root))
    stop(again)


def main():
    with tempfile.TemporaryDirectory() as scratch:
        tmp = Path(scratch)
        scenario_dag(tmp)
        scenario_retry(tmp)
        scenario_stale(tmp)
        scenario_pause(tmp)
        scenario_sigterm(tmp)
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} checks")
        return 1
    print("ok: task-run fixture")
    return 0


if __name__ == "__main__":
    sys.exit(main())
