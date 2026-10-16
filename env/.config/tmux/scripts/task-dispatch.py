#!/usr/bin/env python3
"""Wait for worker turns and route each finished step, so the orchestrator wakes only when a decision is needed (C3).

    task-dispatch.py watch <agent>... [--task-root <dir>]
    task-dispatch.py wait <agent>... [--task-root <dir>]

watch runs as the orchestrator (TASK_ROLE=orchestrator) in the background. For each agent it takes the
first queued step not yet in <task-root>/status.log, waits for that step's turn to start and then settle
(herdr's own agent wait; no early return on an idle agent), checks the report with task-report.py and
routes it with task-decide.py (worker-step formula, TASK_DECIDE_LIVE=1). On route continue it appends one
line to status.log, copies the next queued hook to hooks/<agent>.md, sends the next prompt and keeps
watching. Queue files are queue/<agent>/<NN>-<step>.md (hook body) and .prompt (one line).

wait only waits for each named agent's current turn to settle and reports it; it routes nothing.

Exit codes: 0 queue empty (watch) or settled (wait); 2 usage; 3 invalid formula or report; 10 escalate;
11 ask_user; 12 agent blocked; 13 agent did not start the step; 14 no valid report for the step; 15 turn
timed out; 16 herdr refused or failed a call; 20 decision service unavailable. The 2, 3, 10, 11 and 20
codes come from task-decide. Env: TASK_DISPATCH_START_MS (wait for a turn to start, default 30000),
TASK_DISPATCH_TURN_MS (wait for it to settle, default 4 hours). TASK_SESSION names the herdr session.
Stdlib only.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import queue
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
DECIDE = HERE / "task-decide.py"
REPORT_CHECK = HERE / "task-report.py"
FORMULA = HERE / "task-roles" / "formulas" / "worker-step.toml"
LOG_LINE = re.compile(r"(\S+) (\S+) route=continue step=(\S+)")
QUEUE_FILE = re.compile(r"(\d+)-(.+)\.md")

EMPTY = 0
USAGE = 2
BLOCKED = 12
NOT_STARTED = 13
NO_REPORT = 14
TIMED_OUT = 15
HERDR = 16


class Herdr(Exception):
    """herdr refused a call or failed: exit 16."""


class Timeout(Herdr):
    """A herdr wait ran out of time."""


def herdr(*args):
    """Runs `herdr agent <args>` and returns its result."""
    cmd = ["herdr"]
    if os.environ.get("TASK_SESSION"):
        cmd += ["--session", os.environ["TASK_SESSION"]]
    proc = subprocess.run([*cmd, "agent", *args], capture_output=True, text=True)
    try:
        reply = json.loads(proc.stdout)
    except ValueError:
        raise Herdr(f"herdr agent {args[0]}: no JSON reply: {(proc.stderr or proc.stdout).strip()[:200]}")
    if "error" in reply:
        if reply["error"].get("code") == "timeout":
            raise Timeout("timed out")
        raise Herdr(f"{reply['error'].get('code')}: {reply['error'].get('message')}")
    return reply["result"]


def status(agent):
    return herdr("get", agent)["agent"]["agent_status"]


def wait_status(agent, until, timeout_ms):
    """The agent's status once it matches `until` (default idle, done or blocked); None on timeout."""
    args = ["wait", agent, "--timeout", str(timeout_ms)]
    if until:
        args += ["--until", until]
    try:
        return herdr(*args)["agent"]["agent_status"]
    except Timeout:
        return None


def report_path(root, agent, step):
    return root / "reports" / agent / f"{step}.json"


def await_turn(agent, step, root, start_ms, turn_ms):
    """Waits for the agent's turn on step to start and settle. Returns (None, "") when settled, else (exit code, why).

    The start wait is bounded, so a turn that finished before the wait began still settles: its report
    is then checked. An agent that never starts and has no report for the step is NOT_STARTED.
    """
    started = wait_status(agent, "working", start_ms) is not None or status(agent) == "working"
    if started:
        final = wait_status(agent, None, turn_ms)
        if final is None:
            return TIMED_OUT, f"{agent} still working after {turn_ms} ms"
    else:
        final = status(agent)
    if final == "blocked":
        return BLOCKED, f"{agent} is blocked: a question is waiting in its pane"
    if not started and not report_path(root, agent, step).exists():
        return NOT_STARTED, f"{agent} did not start step {step} within {start_ms} ms"
    return None, ""


def route(agent, step, root):
    """Checks the report and routes it with task-decide. Returns (exit code, one line)."""
    report = report_path(root, agent, step)
    if not report.exists():
        return NO_REPORT, f"no report for step {step}"
    check = subprocess.run([sys.executable, str(REPORT_CHECK), "check", str(report)], capture_output=True, text=True)
    if check.returncode != 0:
        return NO_REPORT, f"report for step {step} fails task-report check: {check.stdout.strip()[:200]}"
    env = {**os.environ, "TASK_DECIDE_LIVE": "1"}
    args = [sys.executable, str(DECIDE), "--formula", str(FORMULA), "--report", str(report), "--step", step, "--task-root", str(root)]
    decide = subprocess.run(args, capture_output=True, text=True, env=env)
    return decide.returncode, (decide.stdout or decide.stderr).strip()


def queued(root, agent):
    """The agent's queued steps in order, as (step, hook file, prompt file)."""
    folder = root / "queue" / agent
    found = []
    for path in folder.glob("*.md") if folder.is_dir() else []:
        match = QUEUE_FILE.fullmatch(path.name)
        if match:
            found.append((int(match[1]), match[2], path))
    return [(step, hook, hook.with_suffix(".prompt")) for _, step, hook in sorted(found)]


def recorded(root, agent):
    """Steps already continued for this agent, from status.log."""
    log = root / "status.log"
    if not log.exists():
        return set()
    matches = (LOG_LINE.match(line) for line in log.read_text(encoding="utf-8").splitlines())
    return {m[3] for m in matches if m and m[2] == agent}


def pending(root, agent):
    done = recorded(root, agent)
    return [item for item in queued(root, agent) if item[0] not in done]


def drive(agent, root, start_ms, turn_ms, lock):
    """Runs one agent's queue until it is empty (EMPTY) or needs the orchestrator. Returns (code, line)."""
    steps = pending(root, agent)
    while steps:
        step, hook, prompt = steps[0]
        code, line = await_turn(agent, step, root, start_ms, turn_ms)
        if code is None:
            code, line = route(agent, step, root)
        if code != 0:
            return code, f"{agent} step {step}: {line}"
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with lock:
            with (root / "status.log").open("a", encoding="utf-8") as log:
                log.write(f"{stamp} {agent} {line}\n")
        steps.pop(0)
        if steps:
            step, hook, prompt = steps[0]
            shutil.copyfile(hook, root / "hooks" / f"{agent}.md")
            herdr("prompt", agent, " ".join(prompt.read_text(encoding="utf-8").split()))
    return EMPTY, f"{agent}: queue empty"


def watch(agents, root, start_ms, turn_ms):
    lock = threading.Lock()
    results = queue.Queue()

    def lane(agent):
        result = (HERDR, f"{agent}: internal error")
        try:
            result = drive(agent, root, start_ms, turn_ms, lock)
        except Herdr as error:
            result = (HERDR, f"{agent}: {error}")
        finally:
            results.put(result)

    for agent in agents:
        threading.Thread(target=lane, args=(agent,), daemon=True).start()
    lines = []
    for _ in agents:
        code, line = results.get()
        if code != EMPTY:
            return code, line
        lines.append(line)
    return EMPTY, "; ".join(lines)


def wait(agents, root, start_ms, turn_ms):
    for agent in agents:
        try:
            code, why = await_turn(agent, "", root, start_ms, turn_ms)
        except Herdr as error:
            return HERDR, f"{agent}: {error}"
        if code is not None:
            return code, why
    return EMPTY, "; ".join(f"{agent}: settled" for agent in agents)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Wait for worker turns and route finished steps.")
    parser.add_argument("command", choices=["watch", "wait"])
    parser.add_argument("agents", nargs="+")
    parser.add_argument("--task-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    start_ms = int(os.environ.get("TASK_DISPATCH_START_MS", 30000))
    turn_ms = int(os.environ.get("TASK_DISPATCH_TURN_MS", 4 * 60 * 60 * 1000))
    if args.command == "watch" and os.environ.get("TASK_ROLE") != "orchestrator":
        print("task-dispatch: watch routes steps for the orchestrator only: TASK_ROLE must be orchestrator", file=sys.stderr)
        return USAGE
    if args.command == "watch":
        code, line = watch(args.agents, args.task_root, start_ms, turn_ms)
    else:
        code, line = wait(args.agents, args.task_root, start_ms, turn_ms)
    print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
