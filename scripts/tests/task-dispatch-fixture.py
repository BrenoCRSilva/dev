#!/usr/bin/env python3
"""Offline checks for task-dispatch.py (C3).

Runs the real task-dispatch.py and task-decide.py against a fake `herdr` on PATH and a local mock of the
decisions endpoint, so there is no network and no real key. The fake agent is time-driven: a prompt
starts a turn that is idle for `start` seconds, working for `work` seconds, then ends idle or blocked and
writes the turn's report. So a wait that begins right after a prompt sees idle, as herdr does. Covers the
continue chain over two queued steps, escalate, ask_user-style stops, blocked, a turn that never starts,
an empty queue, two agents, the orchestrator-only refusal, `wait`, checkpoints, Scope: and Requires:. Writes only inside a temporary folder.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
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

def reply(result=None, error=None):
    print(json.dumps({"id": "fake", "error": error} if error else {"id": "fake", "result": result}))
    sys.exit(1 if error else 0)

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
    else:
        if turn.get("report"):
            Path(turn["report_path"]).parent.mkdir(parents=True, exist_ok=True)
            Path(turn["report_path"]).write_text(json.dumps(turn["report"]), encoding="utf-8")
        st["active"] = None
        st["blocked"] = turn["end"] == "blocked"
        status = turn["end"]
    path.write_text(json.dumps(st), encoding="utf-8")
    return status, st

def info(name, status):
    return {"type": "agent_info", "agent": {"name": name, "agent_status": status}}

command, name = args[1], args[2] if len(args) > 2 else ""
if command == "get":
    status, _ = current(name)
    reply(info(name, status))
if command == "prompt":
    status, st = current(name)
    if status == "blocked":
        reply(error={"code": "agent_blocked", "message": "agent is blocked"})
    if not st["turns"]:
        reply(error={"code": "no_turn", "message": "fixture has no turn left"})
    st["active"], st["turns"] = st["turns"].pop(0), st["turns"]
    st["t0"] = time.time()
    (FAKE / "state" / f"{name}.json").write_text(json.dumps(st), encoding="utf-8")
    with (FAKE / "prompts.log").open("a", encoding="utf-8") as log:
        log.write(f"{name}\t{args[3]}\n")
    reply({"type": "ok"})
if command == "wait":
    until = {args[args.index("--until") + 1]} if "--until" in args else {"idle", "done", "blocked"}
    deadline = time.time() + int(args[args.index("--timeout") + 1]) / 1000
    while True:
        status, _ = current(name)
        if status in until:
            reply(info(name, status))
        if time.time() >= deadline:
            reply(error={"code": "timeout", "message": "timed out waiting for agent status"})
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


def turn(root, step, start=0.3, work=0.5, end="idle", agent=WORKER):
    """A fake turn: idle for start seconds, working for work seconds, then end, with its report."""
    path = root / "reports" / agent / f"{step}.json"
    body = report(step, agent) if end == "idle" else None
    return {"start": start, "work": work, "end": end, "report": body, "report_path": str(path)}


def queue_step(root, number, step, agent=WORKER, head="", extra=""):
    folder = root / "queue" / agent
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{number:02d}-{step}.md").write_text(
        f"{head}# {agent}: step {step}\nScope: env/.config/tmux/scripts/task-dispatch.py\n{extra}", encoding="utf-8"
    )
    (folder / f"{number:02d}-{step}.prompt").write_text(
        f"Read {root}/hooks/{agent}.md and follow it. Step {step}.\nEnd with the SUMMARY block.\n", encoding="utf-8"
    )


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


def load_dispatch():
    """The dispatcher as a module, for the helpers the scenarios do not reach through a run."""
    spec = importlib.util.spec_from_file_location("task_dispatch", DISPATCH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def orchestrator_prompt(env, agent, text):
    """What the orchestrator does before it starts watch: prompt the agent with the step."""
    subprocess.run(["herdr", "agent", "prompt", agent, text], capture_output=True, text=True, env=env, check=True)


def lines(path):
    return path.read_text(encoding="utf-8").splitlines() if path.exists() else []


def main():
    tmp = Path(tempfile.mkdtemp(prefix="task-dispatch-fixture-"))
    try:
        # 1. Continue chain: two queued steps, each routed continue; the second is sent by watch.
        root, fake, env = scenario(tmp, "chain")
        queue_step(root, 1, "6")
        queue_step(root, 2, "7", extra="Requires: report:6:head_sha, file:hooks\n")
        (root / "hooks").mkdir()
        shutil.copyfile(root / "queue" / WORKER / "01-6.md", root / "hooks" / f"{WORKER}.md")
        set_agent(fake, WORKER, [turn(root, "6"), turn(root, "7")])
        Mock.script = [answer(), answer()]
        orchestrator_prompt(env, WORKER, "Read the hook and follow it. Step 6.")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("chain: exits 0 on empty queue", result.returncode, 0)
        expect("chain: summary says queue empty", result.stdout.strip(), f"{WORKER}: queue empty")
        log = lines(root / "status.log")
        check("chain: one status line per step", len(log) == 2 and "step=6" in log[0] and "step=7" in log[1])
        check("chain: both steps continue", all("route=continue" in line for line in log))
        expect("chain: next hook installed", (root / "hooks" / f"{WORKER}.md").read_text(encoding="utf-8"), (root / "queue" / WORKER / "02-7.md").read_text(encoding="utf-8"))
        sent = lines(fake / "prompts.log")
        expect("chain: watch sent step 7's prompt, one line", sent[-1], f"{WORKER}\tRead {root}/hooks/{WORKER}.md and follow it. Step 7. End with the SUMMARY block.")
        check("chain: decisions recorded", (root / "decisions" / WORKER / "7.json").exists())

        # 2. Early-idle race: the wait starts before the agent has begun the turn. It must not return early.
        root, fake, env = scenario(tmp, "race")
        queue_step(root, 1, "6")
        (root / "hooks").mkdir()
        set_agent(fake, WORKER, [turn(root, "6", start=0.4, work=0.5)])
        Mock.script = [answer()]
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("race: routes after the turn, exit 0", result.returncode, 0)
        check("race: report was written by the turn before routing", (root / "reports" / WORKER / "6.json").exists())
        check("race: decision made once", len(Mock.seen) == 1)

        # 3. Escalate: the step's next owner is not the orchestrator. Nothing is recorded or sent.
        root, fake, env = scenario(tmp, "escalate")
        queue_step(root, 1, "6")
        queue_step(root, 2, "7")
        (root / "hooks").mkdir()
        set_agent(fake, WORKER, [turn(root, "6"), turn(root, "7")])
        Mock.script = [answer(owner="worker")]
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("escalate: exit 10", result.returncode, 10)
        check("escalate: names the step and route", "step 6: route=escalate" in result.stdout)
        check("escalate: nothing recorded", not (root / "status.log").exists())
        expect("escalate: no second prompt sent", len(lines(fake / "prompts.log")), 1)

        # 4. Ask user: the agent's turn ends blocked on a question UI.
        root, fake, env = scenario(tmp, "blocked")
        queue_step(root, 1, "6")
        (root / "hooks").mkdir()
        set_agent(fake, WORKER, [turn(root, "6", end="blocked")])
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("blocked: exit 12", result.returncode, 12)

        # 5. The turn never starts and writes no report: exit 13, nothing routed.
        root, fake, env = scenario(tmp, "not-started")
        queue_step(root, 1, "6")
        (root / "hooks").mkdir()
        set_agent(fake, WORKER, [turn(root, "6", start=30)])
        env["TASK_DISPATCH_START_MS"] = "800"
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("not started: exit 13", result.returncode, 13)
        check("not started: no decision made", len(Mock.seen) == 0)

        # 6. Empty queue: exit 0 at once, and herdr is not called.
        root, fake, env = scenario(tmp, "empty")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("empty queue: exit 0", result.returncode, 0)
        expect("empty queue: summary", result.stdout.strip(), f"{WORKER}: queue empty")
        check("empty queue: herdr not called", not (fake / "calls.log").exists())

        # 7. Two agents: one has nothing queued, the other escalates. The escalation wakes the orchestrator.
        root, fake, env = scenario(tmp, "two-agents")
        queue_step(root, 1, "6")
        (root / "hooks").mkdir()
        set_agent(fake, WORKER, [turn(root, "6")])
        Mock.script = [answer(owner="worker")]
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "worker-empty", "--task-root", str(root)], env, root)
        expect("two agents: exit 10 from the escalating agent", result.returncode, 10)
        check("two agents: the agent with no queue is not waited for", "worker-empty" not in result.stdout)

        # 8. wait: one turn settles; nothing is routed, and an idle agent with no turn is reported as not started.
        root, fake, env = scenario(tmp, "wait")
        set_agent(fake, WORKER, [turn(root, "6", start=0.2, work=0.4)])
        orchestrator_prompt(env, WORKER, "go")
        result = run(["wait", WORKER, "--task-root", str(root)], env, root)
        expect("wait: settled turn exits 0", result.returncode, 0)
        check("wait: routes nothing", not (root / "status.log").exists())

        # 10. Checkpoint (front matter): watch stops after the report, logs the step as done and sends nothing more.
        root, fake, env = scenario(tmp, "checkpoint")
        queue_step(root, 1, "6", head="---\ncheckpoint: true\n---\n")
        queue_step(root, 2, "7")
        (root / "hooks").mkdir()
        shutil.copyfile(root / "queue" / WORKER / "01-6.md", root / "hooks" / f"{WORKER}.md")
        set_agent(fake, WORKER, [turn(root, "6"), turn(root, "7")])
        Mock.script = [answer(), answer()]
        orchestrator_prompt(env, WORKER, "Read the hook and follow it. Step 6.")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("checkpoint: exit 17", result.returncode, 17)
        check("checkpoint: logged as checkpoint for step 6", lines(root / "status.log")[0].split()[2:4] == ["route=checkpoint", "step=6"])
        expect("checkpoint: next step not sent", len(lines(fake / "prompts.log")), 1)

        # The orchestrator installs and prompts step 7 itself, then runs watch again: step 6 is not routed twice.
        shutil.copyfile(root / "queue" / WORKER / "02-7.md", root / "hooks" / f"{WORKER}.md")
        orchestrator_prompt(env, WORKER, "Read the hook and follow it. Step 7.")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("checkpoint: resumed watch exits 0 when the queue is done", result.returncode, 0)
        check("checkpoint: step 6 logged once", [line.split()[3] for line in lines(root / "status.log")] == ["step=6", "step=7"])

        # 11. Checkpoint marker beside the hook, no front matter.
        root, fake, env = scenario(tmp, "checkpoint-marker")
        queue_step(root, 1, "6")
        (root / "queue" / WORKER / "01-6.checkpoint").write_text("", encoding="utf-8")
        (root / "hooks").mkdir()
        set_agent(fake, WORKER, [turn(root, "6")])
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("checkpoint marker: exit 17", result.returncode, 17)

        # 12. A file outside Scope: task-decide continues, but watch stops (exit 19), logs nothing and sends nothing more.
        root, fake, env = scenario(tmp, "out-of-scope")
        queue_step(root, 1, "6")
        queue_step(root, 2, "7")
        (root / "hooks").mkdir()
        strayed = turn(root, "6")
        strayed["report"]["files_changed"] = ["env/.config/tmux/scripts/task-spend.py"]
        set_agent(fake, WORKER, [strayed, turn(root, "7")])
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("out of scope: exit 19", result.returncode, 19)
        check("out of scope: names the file", "task-spend.py" in result.stdout)
        check("out of scope: nothing logged", not (root / "status.log").exists())
        expect("out of scope: next step not sent", len(lines(fake / "prompts.log")), 1)

        # 13. Requires: not met before step 7 is installed: exit 21, step 7 is not installed or sent.
        root, fake, env = scenario(tmp, "requires")
        queue_step(root, 1, "6")
        queue_step(root, 2, "7", extra="Requires: file:reports/worker-dotfiles/missing.json\n")
        (root / "hooks").mkdir()
        set_agent(fake, WORKER, [turn(root, "6"), turn(root, "7")])
        orchestrator_prompt(env, WORKER, "go")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("requires: exit 21", result.returncode, 21)
        check("requires: names the item", "missing.json" in result.stdout)
        expect("requires: next step not sent", len(lines(fake / "prompts.log")), 1)
        check("requires: step 6 logged, step 7 not", [line.split()[3] for line in lines(root / "status.log")] == ["step=6"])

        # 14. Helpers, called directly: needs_decision, Scope: globs and plain paths, checkpoint forms, Requires: items.
        module = load_dispatch()
        scratch = tmp / "helpers"
        (scratch / "reports" / WORKER).mkdir(parents=True)
        (scratch / "reports" / WORKER / "6.json").write_text(json.dumps(report("6")), encoding="utf-8")

        def write(name, text):
            path = scratch / name
            path.write_text(text, encoding="utf-8")
            return path

        def report_with(name, **fields):
            return write(name, json.dumps({**report("6"), **fields}))

        scoped = write("01-x.md", "# x\nScope: env/**/*.py, scripts/tests/task-dispatch-fixture.py\n")
        check("helpers: globs and plain paths in scope", module.stop_reason(scoped, report_with("in.json", files_changed=["env/a/b.py", "scripts/tests/task-dispatch-fixture.py"])) is None)
        check("helpers: a file under a plain path is in scope", module.stop_reason(write("02-x.md", "Scope: env/x\n"), report_with("under.json", files_changed=["env/x/y.md"])) is None)
        expect("helpers: a file outside Scope stops", module.stop_reason(scoped, report_with("out.json", files_changed=["env/a.md"]))[0], module.OUT_OF_SCOPE)
        expect("helpers: no Scope line means no file is in scope", module.stop_reason(write("03-x.md", "# x\n"), report_with("none.json", files_changed=["env/a.py"]))[0], module.OUT_OF_SCOPE)
        expect("helpers: needs_decision stops", module.stop_reason(scoped, report_with("nd.json", needs_decision="pick a model", files_changed=[]))[0], module.NEEDS_DECISION)
        check("helpers: first-line checkpoint", module.checkpoint_marked(write("04-x.md", "checkpoint: true\n# x\n")))
        check("helpers: front matter checkpoint", module.checkpoint_marked(write("05-x.md", "---\nstep: 6\ncheckpoint: true\n---\n# x\n")))
        check("helpers: front matter without checkpoint", not module.checkpoint_marked(write("06-x.md", "---\nstep: 6\n---\n# x\n")))
        expect("helpers: checkpoint routes to 17", module.stop_reason(write("07-x.md", "checkpoint: true\nScope: env/**/*.py\n"), report_with("ck.json", files_changed=["env/a.py"]))[0], module.CHECKPOINT)
        check("helpers: Requires report field met", module.unmet_requires(scratch, WORKER, write("08-x.md", "Requires: report:6:head_sha\n")) is None)
        check("helpers: Requires report field unmet", "report:6:nope" in module.unmet_requires(scratch, WORKER, write("09-x.md", "Requires: report:6:nope\n")))
        check("helpers: unknown Requires item stops", "unknown" in module.unmet_requires(scratch, WORKER, write("10-x.md", "Requires: magic:thing\n")))

        # 9. Only the orchestrator may watch.
        root, fake, env = scenario(tmp, "refuse")
        env.pop("TASK_ROLE")
        result = run(["watch", WORKER, "--task-root", str(root)], env, root)
        expect("refuse: exit 2 without TASK_ROLE=orchestrator", result.returncode, 2)
        check("refuse: herdr not called", not (fake / "calls.log").exists())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("PASS: all task-dispatch checks")


if __name__ == "__main__":
    main()
