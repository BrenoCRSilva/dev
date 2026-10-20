#!/usr/bin/env python3
"""Offline checks for the dispatcher's wait command and the removed watch (C3, arch v2 M4 part E1c).

Runs the real task-dispatch.py against a fake `herdr` on PATH and a local mock of the decisions endpoint, so there
is no network and no real key. The fake agent is time-driven: a prompt starts a turn that is idle for `start`
seconds, working for `work` seconds, then ends idle or blocked and writes the turn's report. Covers wait (settled,
blocked, not started, a stale report, herdr timeout slices) and the removed watch command. The helpers are shared
with task-run-fixture.py. Writes only inside a temporary folder.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DISPATCH = ROOT / "env/.config/tmux/scripts/task-dispatch.py"
KEY = "sk-or-v1-FIXTURE-KEY-7f3a9c"
GOOD_MODEL = "typesafe/jev-1.14-20261014"
OPTIONS = ["worker", "researcher", "orchestrator", "none"]
WORKER = "worker-dotfiles"

FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
FAKE = Path(os.environ["FAKE_HERDR"])
args = sys.argv[1:]
with (FAKE / "calls.log").open("a", encoding="utf-8") as log:
    log.write("\t".join(args) + "\n")

def save(path, st):
    # Atomic: a killed daemon can leave a herdr wait running that writes the same state file.
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(st), encoding="utf-8")
    os.replace(tmp, path)

def reply(result=None, error=None):
    # As real herdr: an error reply goes to stderr and stdout stays empty.
    if error:
        print(json.dumps({"id": "fake", "error": error}), file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"id": "fake", "result": result}))
    sys.exit(0)

def current(name):
    path = FAKE / "state" / f"{name}.json"
    if not path.exists():
        reply(error={"code": "agent_not_found", "message": f"agent target {name} not found"})
    st = json.loads(path.read_text(encoding="utf-8"))
    now = time.time()
    turn = st["active"]
    if st["blocked"]:
        status = "blocked"
    elif turn is None:
        status = "idle"
    elif now < st["t0"] + turn["start"]:
        status = "idle"
    elif now < st["t0"] + turn["start"] + turn["work"]:
        status = "working"
    elif now < st["t0"] + turn["start"] + turn["work"] + turn.get("shell", 0):
        status = "idle"  # the turn ended with a background shell running; its report comes when the shell ends
    else:
        if turn.get("report"):
            Path(turn["report_path"]).parent.mkdir(parents=True, exist_ok=True)
            Path(turn["report_path"]).write_text(json.dumps(turn["report"]), encoding="utf-8")
        for target, text in (turn.get("writes") or {}).items():  # files the turn leaves behind, e.g. a researcher's answer
            Path(target).parent.mkdir(parents=True, exist_ok=True)
            Path(target).write_text(text, encoding="utf-8")
        st["active"] = None
        st["blocked"] = turn["end"] == "blocked"
        status = turn["end"]
    save(path, st)
    return status, st

def info(name, status):
    return {"type": "agent_info", "agent": {"name": name, "agent_status": status, "pane_id": f"pane-{name}"}}

command, name = args[1], args[2] if len(args) > 2 else ""
if command == "get":
    status, _ = current(name)
    reply(info(name, status))
if command == "read":  # plain pane text; the footer shows "1 shell" while the turn's background shell runs
    _, st = current(name)
    shell = st.get("shell_from", 0) <= time.time() < st.get("shell_until", 0)
    print("❯\n  ⏵⏵ auto mode on" + (" · 1 shell" if shell else "") + " · esc to interrupt")
    sys.exit(0)
if command == "prompt":
    status, st = current(name)
    if status == "blocked":
        reply(error={"code": "agent_blocked", "message": "agent is blocked"})
    if not st["turns"]:
        reply(error={"code": "no_turn", "message": "fixture has no turn left"})
    st["active"], st["turns"] = st["turns"].pop(0), st["turns"]
    st["t0"] = time.time()
    st["shell_from"] = st["t0"] + st["active"]["start"] + st["active"]["work"]
    st["shell_until"] = st["shell_from"] + st["active"].get("shell", 0)
    save(FAKE / "state" / f"{name}.json", st)
    with (FAKE / "prompts.log").open("a", encoding="utf-8") as log:
        log.write(f"{name}\t{args[3]}\n")
    with (FAKE / "sessions.log").open("a", encoding="utf-8") as log:
        log.write(f"{name}\t{st.get('session', 0)}\n")
    reply({"type": "ok"})
if command == "wait":
    until = {args[args.index("--until") + 1]} if "--until" in args else {"idle", "done", "blocked"}
    deadline = time.time() + int(args[args.index("--timeout") + 1]) / 1000
    while True:
        status, _ = current(name)
        if status in until:
            reply(info(name, status))
        if time.time() >= deadline:
            reply(error={"code": os.environ.get("FAKE_TIMEOUT_CODE", "timeout"), "message": "timed out waiting for agent status"})
        time.sleep(0.02)
sys.exit(2)
'''


class Mock(BaseHTTPRequestHandler):
    script = []  # one (status, payload) per call; the last entry repeats
    seen = []

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        Mock.seen.append(json.loads(raw))
        status, payload = Mock.script[min(len(Mock.seen), len(Mock.script)) - 1]
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


SERVER = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{SERVER.server_address[1]}/api/alpha/decisions"


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def expect(label, got, want):
    if got != want:
        fail(f"{label}: got {got!r}, want {want!r}")
    print(f"PASS: {label}")


def check(label, condition):
    if not condition:
        fail(label)
    print(f"PASS: {label}")


def answer(p_user=0.02, owner="orchestrator", p_owner=0.9):
    probs = {o: p_owner if o == owner else (1 - p_owner) / 3 for o in OPTIONS}
    return 200, {
        "model": GOOD_MODEL,
        "provider": "TypeSafe",
        "answers": {
            "touches_contract": {"type": "noul", "noul": 0.1},
            "needs_user": {"type": "noul", "noul": p_user},
            "next_owner": {"type": "choice", "choice": owner, "probabilities": probs},
        },
        "usage": {"input_tokens": 1000, "output_tokens": 20, "cost": 0.00004},
    }


def report(step, agent=WORKER):
    return {
        "step": step,
        "agent": agent,
        "branch": "investigate-spending",
        "head_sha": "aa95d65",
        "files_changed": ["env/.config/tmux/scripts/task-dispatch.py"],
        "checks": [{"cmd": "python3 -I scripts/tests/task-dispatch-fixture.py", "exit": 0}],
        "risks": [],
        "needs_decision": None,
        "context_estimate_k": 30,
        "summary": f"Step {step} done.",
    }


def turn(root, step, start=0.3, work=0.5, end="idle", agent=WORKER, shell=0.0):
    """A fake turn: idle for start seconds, working for work seconds, then end, with its report. With shell, the turn
    is idle for that many seconds more, its footer shows a background shell, and the report comes when the shell ends."""
    path = root / "reports" / agent / f"{step}.json"
    body = report(step, agent) if end == "idle" else None
    return {"start": start, "work": work, "end": end, "report": body, "report_path": str(path), "shell": shell}


def set_agent(fake, name, turns, blocked=False):
    state = fake / "state"
    state.mkdir(parents=True, exist_ok=True)
    (state / f"{name}.json").write_text(json.dumps({"turns": turns, "active": None, "t0": 0, "blocked": blocked}), encoding="utf-8")


def scenario(tmp, name):
    """A fresh task root, fake herdr and home for one scenario."""
    base = tmp / name
    root, fake, home, bin_dir = base / "task", base / "fake", base / "home", base / "bin"
    for folder in (root, fake, bin_dir, home / ".config/task-agents"):
        folder.mkdir(parents=True, exist_ok=True)
    (bin_dir / "herdr").write_text(FAKE_HERDR, encoding="utf-8")
    (bin_dir / "herdr").chmod(0o755)
    key = home / ".config/task-agents/openrouter.env"
    key.write_text(f"OPENROUTER_API_KEY={KEY}\n", encoding="utf-8")
    key.chmod(0o600)
    Mock.script, Mock.seen = [answer()], []
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "FAKE_HERDR": str(fake),
        "TASK_ROLE": "orchestrator",
        "TASK_DECIDE_ENDPOINT": URL,
        "TASK_DISPATCH_START_MS": "3000",
        "TASK_DISPATCH_TURN_MS": "10000",
    }
    env.pop("TASK_DECIDE_LIVE", None)
    return root, fake, env


def run(args, env, cwd):
    return subprocess.run([sys.executable, str(DISPATCH), *args], capture_output=True, text=True, env=env, cwd=cwd, timeout=120)


def orchestrator_prompt(env, agent, text):
    """What the orchestrator does before it starts watch: prompt the agent with the step."""
    subprocess.run(["herdr", "agent", "prompt", agent, text], capture_output=True, text=True, env=env, check=True)


def lines(path):
    return path.read_text(encoding="utf-8").splitlines() if path.exists() else []


def main():
    tmp = Path(tempfile.mkdtemp(prefix="task-dispatch-fixture-"))
    try:
        # 8. wait: one turn settles; nothing is routed, and an idle agent with no turn is reported as not started.
        root, fake, env = scenario(tmp, "wait")
        set_agent(fake, WORKER, [turn(root, "6", start=0.2, work=0.4)])
        orchestrator_prompt(env, WORKER, "go")
        result = run(["wait", WORKER, "--task-root", str(root)], env, root)
        expect("wait: settled turn exits 0", result.returncode, 0)
        check("wait: routes nothing", not (root / "status.log").exists())

        # 16. A turn that never visibly starts: a report from an earlier run of the step is not routed (exit 13).
        root, fake, env = scenario(tmp, "stale-report")
        (root / "hooks").mkdir()
        stale = root / "reports" / WORKER / "6.json"
        stale.parent.mkdir(parents=True)
        stale.write_text(json.dumps(report("6")), encoding="utf-8")
        hour_ago = time.time() - 3600
        os.utime(stale, (hour_ago, hour_ago))
        set_agent(fake, WORKER, [turn(root, "6", start=30)])
        env["TASK_DISPATCH_START_MS"] = "800"
        orchestrator_prompt(env, WORKER, "go")
        result = run(["wait", WORKER, "--task-root", str(root)], env, root)
        expect("stale report: exit 13", result.returncode, 13)
        check("stale report: no decision made", len(Mock.seen) == 0)

        # 18. A herdr timeout with another code but "timed out" text is a timeout (exit 15 at the deadline, not 16),
        # and the waits run in slices no longer than TASK_DISPATCH_SLICE_MS.
        root, fake, env = scenario(tmp, "slices")
        set_agent(fake, WORKER, [turn(root, "6", start=0.2, work=10)])
        env.update(TASK_DISPATCH_TURN_MS="2500", TASK_DISPATCH_SLICE_MS="1000", FAKE_TIMEOUT_CODE="herdr_wait_failed")
        orchestrator_prompt(env, WORKER, "go")
        result = run(["wait", WORKER, "--task-root", str(root)], env, root)
        expect("slices: still working at the deadline is exit 15", result.returncode, 15)
        waits = [line.split("\t") for line in lines(fake / "calls.log") if line.startswith("agent\twait\t")]
        check("slices: several waits, none longer than a slice", len(waits) >= 4 and all(int(w[w.index("--timeout") + 1]) <= 1000 for w in waits))

        # 9. watch is removed (v2): it prints one line and exits 2 without calling herdr.
        root, fake, env = scenario(tmp, "removed")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("removed: exit 2", result.returncode, 2)
        expect("removed: names run and wake-wait", result.stdout.strip(), "removed: use run + wake-wait")
        check("removed: herdr not called", not (fake / "calls.log").exists())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("PASS: all task-dispatch checks")


if __name__ == "__main__":
    main()
