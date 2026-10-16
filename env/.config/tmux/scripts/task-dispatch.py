#!/usr/bin/env python3
"""Wait for worker turns and route each finished step, so the orchestrator wakes only when a decision is needed (C3).

    task-dispatch.py watch <agent>... [--task-root <dir>]
    task-dispatch.py wait <agent>... [--task-root <dir>]
    task-dispatch.py plan check|reconcile [--task-root <dir>]

run, wake-wait, status, wakes, resolve <wake> continue|retry|skip|cancel [--note] [--release], pause|resume <agent|node>
are the dispatcher commands (C7): run is the background daemon, which installs, starts and evaluates ready nodes
and raises wakes. Its exit codes: 1 daemon stopped (wake-wait), 23 dispatch.lock held, 2 a refused resolve or pause.
    task-dispatch.py run|status|wakes|wake-wait|resolve|pause|resume [--task-root <dir>]

plan check validates plan/dag.toml (C5) and prints `ok N nodes`, or one line per error and exit 2. plan
reconcile applies the plan to state.db (C6) and prints the counts. Neither runs a step.

watch runs as the orchestrator (TASK_ROLE=orchestrator) in the background. For each agent it takes the
first queued step not yet in <task-root>/status.log, waits for that step's turn to start and then settle
(herdr's own agent wait; no early return on an idle agent), checks the report with task-report.py and
routes it with task-decide.py (worker-step formula, TASK_DECIDE_LIVE=1). Then it stops, without sending
anything more, when the report needs a decision (needs_decision set) or changes a file outside the hook's
Scope: line (no Scope: line means no file is in scope), or when the step is a checkpoint. Otherwise it
appends one line to status.log, copies the next queued hook to hooks/<agent>.md, sends the next prompt and
keeps watching. Queue files are queue/<agent>/<NN>-<step>.md (hook body) and .prompt (one line).

A hook is a checkpoint when its first line is `checkpoint: true`, or it opens with front matter that holds
that line, or a `<NN>-<step>.checkpoint` marker sits beside it. A checkpoint step is logged as
`route=checkpoint` and counts as done: watch stops after its report (exit 17), and the orchestrator
installs and prompts the next step itself, then runs watch again.

A hook may carry one `Requires:` line, comma-separated: `file:<path>` (relative to the task root unless
absolute) must exist, and `report:<step>:<field>` needs the step's report to hold a non-empty field. An
unmet item, or an unknown one, stops watch before the step is installed (exit 21).

A stop after a report (18 needs_decision, 19 out-of-scope) is logged as `route=stopped:<reason>`, so a later
watch does not route that report again. task-decide asks the user on needs_decision before watch reads it,
so 18 is a backstop there; 11 is not logged. The orchestrator then decides: accept the step, or queue a fix step with a
new number. Either way, it installs and prompts the next queued step itself, then runs watch again.

wait only waits for each named agent's current turn to settle and reports it; it routes nothing.

Exit codes: 0 queue empty (watch) or settled (wait); 2 usage; 3 invalid formula or report; 10 escalate;
11 ask_user; 12 agent blocked; 13 agent did not start the step; 14 no valid report for the step; 15 turn
timed out; 16 herdr refused or failed a call; 17 checkpoint reached; 18 report sets needs_decision;
19 report changed a file outside Scope:; 20 decision service unavailable; 21 Requires: not met;
22 internal error (a bug here, not herdr; the line starts with internal:).
The 2, 3, 10, 11 and 20 codes come from task-decide. Env: TASK_DISPATCH_START_MS (wait for a turn to start,
default 30000), TASK_DISPATCH_TURN_MS (wait for it to settle, default 4 hours), TASK_DISPATCH_SLICE_MS (the
longest single herdr wait, default 10 minutes). A turn that never visibly starts counts only with a report
written after its prompt; the first step's prompt time is the hook's install time. TASK_SESSION names the
herdr session. Stdlib only.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import queue
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.append(str(HERE))
import task_plan  # noqa: E402 (sibling modules, found through the path above)
import task_state  # noqa: E402
DECIDE = HERE / "task-decide.py"
REPORT_CHECK = HERE / "task-report.py"
FORMULA = HERE / "task-roles" / "formulas" / "worker-step.toml"
LOG_LINE = re.compile(r"(\S+) (\S+) route=(continue|checkpoint|stopped:\w+) step=(\S+)")
QUEUE_FILE = re.compile(r"(\d+)-(.+)\.md")
SLICE_MS = int(os.environ.get("TASK_DISPATCH_SLICE_MS", 10 * 60 * 1000))

EMPTY = 0
USAGE = 2
BLOCKED = 12
NOT_STARTED = 13
NO_REPORT = 14
TIMED_OUT = 15
HERDR = 16
CHECKPOINT = 17
NEEDS_DECISION = 18
OUT_OF_SCOPE = 19
REQUIRES_UNMET = 21
INTERNAL = 22
CHECKS_FAILED = 24
BUDGET = 25
STALE = 26
QUESTION = 27
LOCKED = 23
DAEMON_STOPPED = 1
ASK_USER = 11
STOP_NAMES = {NEEDS_DECISION: "needs_decision", OUT_OF_SCOPE: "out_of_scope", CHECKS_FAILED: "checks", BUDGET: "budget", 10: "escalate", ASK_USER: "ask_user", 20: "decision_unavailable", QUESTION: "question"}
FAIL_NAMES = {BLOCKED: "blocked", NOT_STARTED: "not_started", TIMED_OUT: "timed_out", HERDR: "herdr", INTERNAL: "internal", NO_REPORT: "no_report", STALE: "stale_report"}
V2_COMMANDS = ("run", "wake-wait", "status", "wakes", "resolve", "pause", "resume")
TICK_S = 1
STOP_ROUTES = {NEEDS_DECISION: "stopped:needs_decision", OUT_OF_SCOPE: "stopped:out_of_scope"}


def _task_decide():
    """task-decide as a module: its glob matcher, so Scope: globs and safety globs mean the same thing, and its safety rule set."""
    spec = importlib.util.spec_from_file_location("task_decide", DECIDE)
    assert spec is not None and spec.loader is not None, DECIDE
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DECIDE_MODULE = _task_decide()
glob_regex = DECIDE_MODULE.glob_regex


class Herdr(Exception):
    """herdr refused a call or failed: exit 16."""


class Timeout(Herdr):
    """A herdr wait ran out of time."""


class Launch(Exception):
    """A fresh session could not be started (task-agent.sh or the agent's state): the node fails."""


def _reply(text):
    """The JSON object in text, or None when there is none."""
    try:
        reply = json.loads(text)
    except ValueError:
        return None
    return reply if isinstance(reply, dict) else None


def herdr(*args):
    """Runs `herdr agent <args>` and returns its result. herdr writes an error reply to stderr with stdout empty."""
    cmd = ["herdr"]
    if os.environ.get("TASK_SESSION"):
        cmd += ["--session", os.environ["TASK_SESSION"]]
    proc = subprocess.run([*cmd, "agent", *args], capture_output=True, text=True)
    reply = _reply(proc.stdout)
    if reply is None:
        reply = _reply(proc.stderr)
    if reply is None:
        raise Herdr(f"herdr agent {args[0]}: no JSON reply: {(proc.stderr or proc.stdout).strip()[:200]}")
    if "error" in reply:
        error = reply["error"]
        if error.get("code") == "timeout" or "timed out" in str(error.get("message", "")):
            raise Timeout("timed out")
        raise Herdr(f"{error.get('code')}: {error.get('message')}")
    return reply["result"]


def status(agent):
    return herdr("get", agent)["agent"]["agent_status"]


def canonical_repo(root, agent):
    """The canonical checkout of a worker's repo: the AGENTS.md Repo modes line that names its agent."""
    try:
        lines = (root / "AGENTS.md").read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise Launch(f"cannot read AGENTS.md: {error}")
    for line in lines:
        match = re.search(r"canonical checkout `([^`]+)`", line)
        if match and f"agent `{agent}`" in line:
            return match[1]
    raise Launch(f"AGENTS.md Repo modes has no canonical checkout for {agent}")


def task_agent(*args):
    """Runs task-agent.sh (TASK_AGENT_SCRIPT overrides the path in tests). Raises Launch when it fails."""
    proc = subprocess.run([os.environ.get("TASK_AGENT_SCRIPT", str(HERE / "task-agent.sh")), *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise Launch(f"task-agent.sh {' '.join(args[:2])} exit {proc.returncode}: {(proc.stderr or proc.stdout).strip()[-200:]}")


def relaunch(root, agent):
    """session=fresh: ends the agent's session and starts a new one in its pane, with no --resume. The hook is
    already installed, so the new session reads it. The start arguments are checked before the session is ended."""
    info = herdr("get", agent)["agent"]
    if info["agent_status"] not in ("idle", "done"):
        raise Launch(f"{agent} is {info['agent_status']}, not idle, so it cannot start a fresh session")
    if agent == "researcher":
        start = ["start", "researcher", info["pane_id"]]
    elif agent.startswith("worker-"):
        start = ["start", "worker", agent[len("worker-"):], info["pane_id"], canonical_repo(root, agent)]
    else:
        raise Launch(f"{agent} cannot start a fresh session; use session = \"continue\"")
    task_agent("stop", agent)
    task_agent(*start)


def wait_status(agent, until, timeout_ms):
    """The agent's status once it matches `until` (default idle, done or blocked); None on timeout.

    herdr's wait runs in slices, so no single call asks herdr for a long timeout.
    """
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        left = max(0, round((deadline - time.monotonic()) * 1000))
        args = ["wait", agent, "--timeout", str(min(left, SLICE_MS))]
        if until:
            args += ["--until", until]
        try:
            return herdr(*args)["agent"]["agent_status"]
        except Timeout:
            if left <= SLICE_MS:
                return None


def installed_at(root, agent):
    """When the agent's hook was installed: the first step's prompt time, since the orchestrator installs the hook just before it prompts."""
    hook = root / "hooks" / f"{agent}.md"
    return hook.stat().st_mtime if hook.exists() else None


def fresh_report(path, since):
    """True when the report exists and was written at or after the prompt (since, epoch seconds)."""
    return since is not None and path.exists() and path.stat().st_mtime >= since


def report_path(root, agent, step):
    return root / "reports" / agent / f"{step}.json"


def await_turn(agent, step, root, start_ms, turn_ms, since):
    """Waits for the agent's turn on step to start and settle. Returns (None, "") when settled, else (exit code, why).

    The start wait is bounded, so a turn that finished before the wait began still settles: its report
    is then checked. A turn that never visibly starts counts only with a report written at or after
    `since` (the prompt time); an older report is from an earlier run of the step. Otherwise NOT_STARTED.
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
    if not started and not fresh_report(report_path(root, agent, step), since):
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
    return {m[4] for m in matches if m and m[2] == agent}


def pending(root, agent):
    done = recorded(root, agent)
    return [item for item in queued(root, agent) if item[0] not in done]


def checkpoint_marked(hook):
    """True when the hook's first line, or its front matter, says checkpoint: true, or a .checkpoint marker sits beside it."""
    if hook.with_suffix(".checkpoint").exists():
        return True
    lines = hook.read_text(encoding="utf-8").splitlines()
    head = lines[1 : lines.index("---", 1)] if lines[:1] == ["---"] and "---" in lines[1:] else lines[:1]
    return any(re.fullmatch(r"checkpoint:\s*true", line.strip()) for line in head)


def scope_regexes(hook):
    """The worktree paths the hook's Scope: line allows. A plain path also covers the files under it."""
    match = re.search(r"^Scope:\s*(.*)$", hook.read_text(encoding="utf-8"), re.M)
    regexes = []
    for item in (match[1].split(",") if match else []):
        item = item.strip().strip("`").rstrip("/")
        if not item or item == "none":
            continue
        if re.search(r"[*?]", item):
            regexes.append(glob_regex(item))
        else:
            regexes += [glob_regex(item), glob_regex(item + "/**/*")]
    return regexes


def stop_reason(hook, report):
    """Why watch stops after this step's report, as (code, why), or None to continue."""
    data = json.loads(report.read_text(encoding="utf-8"))
    if data.get("needs_decision"):
        return NEEDS_DECISION, f"needs_decision is set: {str(data['needs_decision'])[:200]}"
    regexes = scope_regexes(hook)
    outside = [path for path in data.get("files_changed", []) if not any(r.match(path) for r in regexes)]
    if outside:
        return OUT_OF_SCOPE, f"changed outside Scope: {', '.join(outside)}"[:300]
    if checkpoint_marked(hook):
        return CHECKPOINT, "checkpoint step: review it, then install and prompt the next step, then run watch"
    return None


def unmet_requires(root, agent, hook):
    """The first Requires: item of the hook that does not hold, as text, or None when all hold (or none is set)."""
    match = re.search(r"^Requires:\s*(.+)$", hook.read_text(encoding="utf-8"), re.M)
    for item in (match[1].split(",") if match else []):
        item = item.strip().strip("`")
        if not item:
            continue
        if item.startswith("file:"):
            path = Path(item[5:])
            held = (path if path.is_absolute() else root / path).exists()
        elif item.startswith("report:"):
            step, _, field = item[7:].partition(":")
            try:
                held = bool(json.loads(report_path(root, agent, step).read_text(encoding="utf-8")).get(field))
            except (OSError, ValueError, AttributeError):
                held = False
        else:
            return f"unknown Requires item {item}"
        if not held:
            return f"Requires {item} is not met"
    return None


def record(root, agent, step, report, route, lock):
    """Appends the step's status.log line. A stop is logged too, so a later watch does not route the same report."""
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    head = json.loads(report.read_text(encoding="utf-8"))["head_sha"]
    with lock:
        with (root / "status.log").open("a", encoding="utf-8") as log:
            log.write(f"{stamp} {agent} route={route} step={step} report={report.relative_to(root)} head_sha={head}\n")


def drive(agent, root, start_ms, turn_ms, lock):
    """Runs one agent's queue until it is empty (EMPTY) or needs the orchestrator. Returns (code, line)."""
    steps = pending(root, agent)
    if steps and (why := unmet_requires(root, agent, steps[0][1])):
        return REQUIRES_UNMET, f"{agent} step {steps[0][0]}: {why}"
    since = installed_at(root, agent)
    while steps:
        step, hook, prompt = steps[0]
        code, line = await_turn(agent, step, root, start_ms, turn_ms, since)
        if code is None:
            code, line = route(agent, step, root)
        if code != 0:
            return code, f"{agent} step {step}: {line}"
        report = report_path(root, agent, step)
        stop = stop_reason(hook, report)
        if stop and stop[0] != CHECKPOINT:
            record(root, agent, step, report, STOP_ROUTES[stop[0]], lock)
            return stop[0], f"{agent} step {step}: {stop[1]}"
        record(root, agent, step, report, "checkpoint" if stop else "continue", lock)
        steps.pop(0)
        if stop:
            return CHECKPOINT, f"{agent} step {step}: {stop[1]}"
        if steps:
            step, hook, prompt = steps[0]
            if why := unmet_requires(root, agent, hook):
                return REQUIRES_UNMET, f"{agent} step {step}: {why}"
            shutil.copyfile(hook, root / "hooks" / f"{agent}.md")
            since = time.time()
            herdr("prompt", agent, " ".join(prompt.read_text(encoding="utf-8").split()))
    return EMPTY, f"{agent}: queue empty"


def watch(agents, root, start_ms, turn_ms):
    lock = threading.Lock()
    results = queue.Queue()

    def lane(agent):
        result = (INTERNAL, f"internal: {agent}: lane ended without a result")
        try:
            result = drive(agent, root, start_ms, turn_ms, lock)
        except Herdr as error:
            result = (HERDR, f"{agent}: {error}")
        except Exception as error:
            result = (INTERNAL, f"internal: {agent}: {error!r}")
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
            code, why = await_turn(agent, "", root, start_ms, turn_ms, None)
        except Herdr as error:
            return HERDR, f"{agent}: {error}"
        if code is not None:
            return code, why
    return EMPTY, "; ".join(f"{agent}: settled" for agent in agents)


# --- dispatcher daemon (C7, arch v2 §4-§6) ---------------------------------------
# One thread per running node waits for its turn and evaluates it (T0 rules, then task-decide). Threads do no
# state writes: they put (node, code, line) on a queue, and only the main loop writes state.db, one transaction
# per transition. A node is pending, ready, running, done, stopped, failed or cancelled (state.db). A checkpoint
# node is never installed: when ready it raises one 'checkpoint' wake, and `resolve continue` passes it.
# `resolve` applies to the wake's node: continue (checkpoint passes; a stopped or failed node with an accepted report
# is accepted), retry (stopped or failed back to pending, a new attempt), skip (done with route skipped, or
# continue with --release so successors start), cancel (cancelled, kept until its plan entry changes).
# pause and resume hold back installs for an agent or a node. Session fresh relaunches the agent through task-agent.sh
# (stop, then start in the same pane) after the hook is written; continue prompts the live session.

STOP = threading.Event()


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def lock_holder(root):
    """The pid holding dispatch.lock, -1 when the file is there but empty, None when no live holder."""
    path = root / "dispatch.lock"
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not text:
        return -1
    try:
        pid = int(text)
    except ValueError:
        return None
    return pid if pid_alive(pid) else None


def take_lock(root):
    """Writes dispatch.lock with this pid. Returns None on success, else the live holder (-1 when its pid is unknown).
    A lock whose pid is dead is stale and is replaced."""
    path = root / "dispatch.lock"
    while True:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            holder = lock_holder(root)
            if holder is not None:
                return holder
            path.unlink(missing_ok=True)
            continue
        os.write(fd, f"{os.getpid()}\n".encode())
        os.close(fd)
        return None


def hook_text(root, nodes, node, attempt):
    """The pointer-sized hook for a node's attempt: spec, report, scope, contracts and the reports it depends on."""
    lines = [
        f"# {node.id} (attempt {attempt})",
        f"Spec: {root / node.spec}" if node.spec else "Spec: none",
        f"Report: reports/{node.agent}/{node.id}.json",
        f"Scope: {', '.join(node.scope) or 'none'}",
        f"Contracts: {', '.join(node.contracts) or 'none'}",
    ]
    for dep in node.after:
        if dep.startswith("q:"):
            lines.append(f"After: research/answers/{dep[2:]}.md")
        else:
            lines.append(f"After: reports/{nodes[dep].agent}/{dep}.json")
    return "\n".join(lines) + "\n"


def evaluate(root, agent, node, scope, budget):
    """T0 rules, free and first: needs_decision, blocking questions, checks exit 0, files within scope, no safety
    paths, context and turns within budget. Then the report check and task-decide (v1). Returns (exit code, one line);
    0 means continue."""
    report = report_path(root, agent, node)
    try:
        data = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return NO_REPORT, f"no readable report for {node}"
    if data.get("needs_decision"):
        return NEEDS_DECISION, f"needs_decision is set: {str(data['needs_decision'])[:200]}"
    blocking = [str(q.get("text", ""))[:200] for q in data.get("questions", []) if q.get("blocking")]
    if blocking:
        return QUESTION, f"blocking question: {blocking[0]}"
    failed = [check.get("cmd", "?") for check in data.get("checks", []) if check.get("exit") != 0]
    if failed:
        return CHECKS_FAILED, f"checks not all exit 0: {', '.join(failed)}"[:300]
    regexes = [glob_regex(pattern) for pattern in scope]
    outside = [path for path in data.get("files_changed", []) if not any(r.match(path) for r in regexes)]
    if outside:
        return OUT_OF_SCOPE, f"changed outside scope: {', '.join(outside)}"[:300]
    hit = DECIDE_MODULE.safety_hit(DECIDE_MODULE.load_formula(FORMULA), data)
    if hit:
        return ASK_USER, f"safety: {hit}"[:300]
    if (data.get("context_estimate_k") or 0) > budget["prompt_k"]:
        return BUDGET, f"context estimate {data['context_estimate_k']}k is over the {budget['prompt_k']}k budget"
    if "turns" in data and data["turns"] > budget["turns"]:
        return BUDGET, f"turns {data['turns']} is over the {budget['turns']}-turn budget"
    return route(agent, node, root)


def turn_outcome(root, agent, node, scope, budget, since, start_ms, turn_ms):
    try:
        code, line = await_turn(agent, node, root, start_ms, turn_ms, since)
        if code is not None:
            return code, line
        # A report from before this attempt's prompt is not this turn's: it fails the node before any evaluation.
        report = report_path(root, agent, node)
        if report.exists() and not fresh_report(report, since):
            return STALE, f"report for {node} was written before its prompt"
        return evaluate(root, agent, node, scope, budget)
    except Herdr as error:
        return HERDR, f"{agent}: {error}"
    except Exception as error:
        return INTERNAL, f"internal: {node}: {error!r}"


def spawn(results, root, agent, node, scope, budget, since, start_ms, turn_ms):
    def lane():
        results.put((node, *turn_outcome(root, agent, node, scope, budget, since, start_ms, turn_ms)))

    threading.Thread(target=lane, daemon=True).start()


def stop_node(conn, node, kind, name, reason, tier="opus"):
    """Routes the running node stopped or failed, and raises the wake for Opus (or the user) that says why."""
    task_state.route(conn, node, f"{kind}:{name}", reason, tier)
    task_state.wake(conn, node, tier, name, reason)


def finish(conn, root, node, code, line, plan):
    """Settles a finished turn: writes the report to state if it is fresh, then routes the node by the outcome. A passing
    node with review: opus also raises an Opus wake; its successors are not held for it."""
    agent = task_state.snapshot(conn)["nodes"][node]["agent"]
    if code in FAIL_NAMES:
        return stop_node(conn, node, "failed", FAIL_NAMES[code], line)
    report = report_path(root, agent, node)
    try:
        data = json.loads(report.read_text(encoding="utf-8"))
        mtime = report.stat().st_mtime
    except (OSError, ValueError):
        return stop_node(conn, node, "failed", "no_report", f"no readable report for {node}")
    if not task_state.settle(conn, node, str(report.relative_to(root)), mtime, data.get("head_sha")):
        return stop_node(conn, node, "failed", "stale_report", f"report for {node} was written before its prompt")
    if code == 0:
        task_state.route(conn, node, "continue")
        if node in plan and plan[node].review == "opus":
            task_state.wake(conn, node, "opus", "review", "review=opus: check this step before relying on it")
        return None
    return stop_node(conn, node, "stopped", STOP_NAMES.get(code, "decide"), line, "user" if code == ASK_USER else "opus")


def tick(conn, root, nodes, start_ms, turn_ms, results):
    """Reconciles the plan, then installs and starts each ready node that is not paused. A node whose work raises fails
    failed:internal; the others still start."""
    task_state.reconcile(conn, nodes)
    held = task_state.paused(conn)
    live = {key: node for key, node in nodes.items() if key not in held and node.agent not in held}
    for node_id in task_plan.ready(live, task_state.snapshot(conn)):
        try:
            launch(conn, root, nodes, node_id, start_ms, turn_ms, results)
        except Exception as error:
            task_state.fail_internal(conn, node_id, repr(error))


def launch(conn, root, nodes, node_id, start_ms, turn_ms, results):
    """Installs and starts one ready node, or raises its checkpoint wake."""
    node = nodes[node_id]
    if node.checkpoint:
        task_state.wake_once(conn, node_id, "opus", "checkpoint", f"checkpoint {node_id}: review, then resolve continue")
        return
    attempt = task_state.install(conn, node_id, node.budget)
    (root / "hooks").mkdir(exist_ok=True)
    (root / "hooks" / f"{node.agent}.md").write_text(hook_text(root, nodes, node, attempt), encoding="utf-8")
    # The node is running before anything can fail, so a failed start routes it failed. prompt_at is taken before the
    # relaunch: a report written during it is from this attempt, and an older one is still rejected.
    prompt_at = time.time()
    task_state.start(conn, node_id, prompt_at=prompt_at)
    try:
        if node.session == "fresh":
            relaunch(root, node.agent)
        herdr("prompt", node.agent, f"Read {root}/hooks/{node.agent}.md and follow it. End with the SUMMARY block.")
    except (Herdr, Launch) as error:
        stop_node(conn, node_id, "failed", "herdr" if isinstance(error, Herdr) else "launch", str(error))
        return
    spawn(results, root, node.agent, node_id, node.scope, node.budget, prompt_at, start_ms, turn_ms)


def load_nodes(conn, root):
    """The plan's nodes, or None while plan/dag.toml is invalid (the tick is skipped). An invalid plan is recorded with
    one plan-invalid wake; a valid one clears the record."""
    try:
        nodes = task_plan.load_plan(root)
    except task_plan.PlanError as error:
        task_state.plan_invalid(conn, error.errors[0])
        return None
    task_state.plan_valid(conn)
    return nodes


def daemon(root, start_ms, turn_ms):
    held = take_lock(root)
    if held is not None:
        print(f"dispatch.lock held by pid {held}" if held > 0 else "dispatch.lock held (pid unknown)")
        return LOCKED
    STOP.clear()
    signal.signal(signal.SIGTERM, lambda *_: STOP.set())
    signal.signal(signal.SIGINT, lambda *_: STOP.set())
    results = queue.Queue()
    conn = None
    try:
        conn = task_state.connect(root)
        print(f"dispatcher started (pid {os.getpid()})", flush=True)
        known = load_nodes(conn, root) or {}
        for row in task_state.running(conn):
            # A running node stays running across a restart: watch its turn again from its prompt time.
            node = known.get(row["id"])
            budget = node.budget if node else task_plan.DEFAULTS["budget"]
            spawn(results, root, row["agent"], row["id"], node.scope if node else [], budget, row["prompt_at"], start_ms, turn_ms)
        while not STOP.is_set():
            nodes = load_nodes(conn, root)
            if nodes is not None:
                known = nodes
                tick(conn, root, nodes, start_ms, turn_ms, results)
            try:
                node, code, line = results.get(timeout=TICK_S)
            except queue.Empty:
                continue
            try:
                finish(conn, root, node, code, line, known)
            except Exception as error:
                task_state.fail_internal(conn, node, repr(error))
    finally:
        if conn is not None:
            conn.close()
        if lock_holder(root) == os.getpid():
            (root / "dispatch.lock").unlink(missing_ok=True)
    print("dispatcher stopped", flush=True)
    return EMPTY


def wake_line(row):
    return f"wake {row['id']} {row['tier']} {row['node']} {row['rule']}: {row['reason']}"


def wake_wait(root, poll_s=1.0, start_grace_s=10.0):
    """Returns at the first open wake, or once the daemon has stopped. A daemon started just before this call has
    start_grace_s to take dispatch.lock; after it has held the lock, the lock going away means it stopped."""
    begun = time.monotonic()
    seen = False
    while True:
        conn = task_state.connect(root)
        try:
            rows = task_state.open_wakes(conn)
        finally:
            conn.close()
        if rows:
            print(wake_line(rows[0]))
            return EMPTY
        held = lock_holder(root) is not None
        seen = seen or held
        if (not held) if seen else time.monotonic() - begun > start_grace_s:
            print("dispatcher stopped: no wake")
            return DAEMON_STOPPED
        time.sleep(poll_s)


def status_main(root):
    try:
        task_plan.load_plan(root)
    except task_plan.PlanError as error:
        print(f"plan: INVALID {error.errors[0]}")
    holder = lock_holder(root)
    print(f"dispatcher: running pid {holder}" if holder else "dispatcher: stopped")
    conn = task_state.connect(root)
    try:
        rows = [dict(row) for row in conn.execute("SELECT * FROM nodes ORDER BY rowid")]
        held = task_state.paused(conn)
        wakes = len(task_state.open_wakes(conn))
    finally:
        conn.close()
    for agent in sorted({row["agent"] for row in rows}):
        mine = [row for row in rows if row["agent"] == agent]
        running = [f"{row['id']} (attempt {row['attempt']})" for row in mine if row["status"] == "running"]
        counts = {}
        for row in mine:
            counts[row["status"]] = counts.get(row["status"], 0) + 1
        tail = " [paused]" if agent in held else ""
        print(f"{agent}: {'running ' + ', '.join(running) if running else 'idle'}; " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + tail)
    print(f"counts: {len(rows)} nodes, {wakes} open wakes")
    return EMPTY


def v2_main(argv):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--task-root", type=Path, default=Path.cwd())
    parser = argparse.ArgumentParser(prog="task-dispatch.py", description="Run the dispatcher and read or resolve its wakes (C7).")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("run", "wake-wait", "status", "wakes"):
        sub.add_parser(name, parents=[common])
    resolve_parser = sub.add_parser("resolve", parents=[common])
    resolve_parser.add_argument("wake", type=int)
    resolve_parser.add_argument("resolution", choices=task_state.RESOLUTIONS)
    resolve_parser.add_argument("--note", default="")
    resolve_parser.add_argument("--release", action="store_true")
    for name in ("pause", "resume"):
        sub.add_parser(name, parents=[common]).add_argument("target")
    args = parser.parse_args(argv)
    root = args.task_root
    if args.command == "run":
        start_ms = int(os.environ.get("TASK_DISPATCH_START_MS", 30000))
        turn_ms = int(os.environ.get("TASK_DISPATCH_TURN_MS", 4 * 60 * 60 * 1000))
        return daemon(root, start_ms, turn_ms)
    if args.command == "wake-wait":
        return wake_wait(root)
    if args.command == "status":
        return status_main(root)
    conn = task_state.connect(root)
    try:
        if args.command == "wakes":
            for row in task_state.open_wakes(conn):
                print(wake_line(row))
            return EMPTY
        if args.command == "resolve":
            task_state.resolve(conn, args.wake, args.resolution, release=args.release, note=args.note)
            print(f"resolved wake {args.wake}: {args.resolution}")
            return EMPTY
        task_state.pause(conn, args.target, paused=args.command == "pause")
        print(f"{args.command}d {args.target}")
        return EMPTY
    except (sqlite3.Error, task_state.TransitionError) as error:
        print(f"refused: {error}")
        return USAGE
    finally:
        conn.close()


def plan_main(argv):
    """`plan check` validates plan/dag.toml; `plan reconcile` brings state.db in line with it (C5, C6)."""
    parser = argparse.ArgumentParser(prog="task-dispatch.py plan", description="Check the plan graph, or reconcile the runtime state with it.")
    parser.add_argument("command", choices=["check", "reconcile"])
    parser.add_argument("--task-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    try:
        nodes = task_plan.load_plan(args.task_root)
    except task_plan.PlanError as error:
        for line in error.errors:
            print(line)
        return USAGE
    if args.command == "check":
        print(f"ok {len(nodes)} nodes")
        return 0
    try:
        conn = task_state.connect(args.task_root)
        try:
            counts = task_state.reconcile(conn, nodes)
        finally:
            conn.close()
    except (sqlite3.Error, task_state.TransitionError) as error:
        print(f"state.db: {error}")
        return INTERNAL
    print("reconcile: " + ", ".join(f"{key} {value}" for key, value in counts.items()))
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["plan"]:
        return plan_main(argv[1:])
    if argv[:1] and argv[0] in V2_COMMANDS:
        return v2_main(argv)
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
