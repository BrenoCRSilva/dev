#!/usr/bin/env python3
"""Offline checks for task-decide.py and jev-probe.py.

Runs both against a local mock of the decisions endpoint, so there is no network
and no real key. Covers the dry-run request body, every exit code, the ZDR and
model refusals, key handling, retries, and the probe's dry run and live scoring.
Checks that the key never appears in any output or record. Writes only inside a
temporary folder.
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
SCRIPTS = ROOT / "env/.config/tmux/scripts"
CLI = SCRIPTS / "task-decide.py"
PROBE = ROOT / "scripts/jev-probe.py"
FORMULA = SCRIPTS / "task-roles/formulas/worker-step.toml"
KEY = "sk-or-v1-FIXTURE-KEY-7f3a9c"
GOOD_MODEL = "typesafe/jev-1.14-20261014"
OPTIONS = ["worker", "researcher", "orchestrator", "none"]


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def passed(label):
    print(f"PASS: {label}")


def expect(label, got, want):
    if got != want:
        fail(f"{label}: got {got!r}, want {want!r}")
    passed(label)


def load_decide():
    spec = importlib.util.spec_from_file_location("task_decide", CLI)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DD = load_decide()


class Mock(BaseHTTPRequestHandler):
    script = []  # (status, payload) per call; the last entry repeats
    seen = []  # (authorization header, request body) per call

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        Mock.seen.append((self.headers.get("Authorization"), json.loads(raw)))
        status, payload = Mock.script[min(len(Mock.seen), len(Mock.script)) - 1]
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


SERVER = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{SERVER.server_address[1]}/api/alpha/decisions"


def mock(*script):
    Mock.script = list(script)
    Mock.seen = []


def answer(p_contract=0.1, p_user=0.1, owner="worker", p_owner=0.9, model=GOOD_MODEL, provider="TypeSafe"):
    probs = {o: p_owner if o == owner else (1 - p_owner) / 3 for o in OPTIONS}
    return 200, {
        "model": model,
        "provider": provider,
        "answers": {
            "touches_contract": {"type": "noul", "noul": p_contract},
            "needs_user": {"type": "noul", "noul": p_user},
            "next_owner": {"type": "choice", "choice": owner, "probabilities": probs},
        },
        "usage": {"input_tokens": 1000, "output_tokens": 20, "cost": 0.00004},
    }


def write_report(root, step="12c", agent="worker-dotfiles", checks=None, needs=None, **changes):
    report = {
        "step": step,
        "agent": agent,
        "branch": "improve-omarchy-agents",
        "head_sha": "2ed9c0a",
        "files_changed": ["env/.config/tmux/scripts/task-decide.py"],
        "checks": [{"cmd": "shellcheck task-decide.py", "exit": 0}] if checks is None else checks,
        "risks": [],
        "needs_decision": needs,
        "context_estimate_k": 30,
        "summary": "Decision routing fixture.",
    }
    report.update(changes)
    path = root / "reports" / agent / f"{step}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report), encoding="utf-8")
    return path


LIVE = {"TASK_ROLE": "orchestrator", "TASK_DECIDE_LIVE": "1"}
KEY_LINE = f'OPENROUTER_API_KEY="{KEY}"\n'


def run_cli(args, home, env=None, timeout=120):
    """Runs a script with an isolated HOME and only the given live-gate variables."""
    environ = {k: v for k, v in os.environ.items() if k not in ("OPENROUTER_API_KEY", "TASK_ROLE", "TASK_DECIDE_LIVE")}
    environ.update({"HOME": str(home), "TASK_DECIDE_ENDPOINT": URL})
    environ.update(env or {})
    try:
        proc = subprocess.run([sys.executable, "-I", *args], env=environ, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(f"{Path(args[0]).name} did not return: it opened the key file, which a refusal must not do")
    if KEY in proc.stdout + proc.stderr:
        fail(f"the key was printed by {Path(args[0]).name}")
    return proc.returncode, proc.stdout, proc.stderr


def decide_cli(report, home, *extra, env=LIVE, step="12c"):
    return run_cli([str(CLI), "--formula", str(FORMULA), "--report", str(report), "--step", step, *extra], home, env)


def key_path(home):
    return home / ".config/task-agents/openrouter.env"


def write_key(home, text, mode=0o600):
    path = key_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        path.unlink()
    path.write_text(text, encoding="utf-8")
    os.chmod(path, mode)


def sentinel_key(home, mode):
    """A FIFO where the key file goes: opening it for reading blocks, so a refusal that returns never opened it."""
    path = key_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        path.unlink()
    os.mkfifo(path)
    os.chmod(path, mode)


def read_record(task, agent="worker-dotfiles", step="12c"):
    text = (task / "decisions" / agent / f"{step}.json").read_text(encoding="utf-8")
    if KEY in text:
        fail("the key was written into a decision record")
    return json.loads(text)


def expect_invalid(tmp, label, text, fragment):
    path = tmp / "bad-formula.toml"
    path.write_text(text, encoding="utf-8")
    try:
        DD.load_formula(path)
    except DD.Invalid as error:
        if fragment not in str(error):
            fail(f"{label}: message {error!r} lacks {fragment!r}")
        passed(label)
        return
    fail(f"{label}: accepted")


def check_formula_rules(tmp, formula_text):
    expect_invalid(tmp, "formula with an unknown key is refused", formula_text.replace("version = 1", "version = 1\nsurprise = true", 1), "unknown key surprise")
    expect_invalid(tmp, "never list without push is refused", formula_text.replace('"merge", "push", ', '"merge", ', 1), "must list merge, push")
    expect_invalid(tmp, "route outside continue/escalate/ask_user is refused", formula_text.replace('route_if_false = "continue"', 'route_if_false = "maybe"', 1), "route must be one of")
    expect_invalid(tmp, "noul criteria without false is refused", formula_text.replace('false = "internal to one repo, or research only"', 'other = "x"', 1), "exactly true and false")
    expect_invalid(tmp, "instructions that do not name a read field are refused", formula_text.replace("(state: files_changed, summary)", "", 1), "must name files_changed")
    expect_invalid(tmp, "a model that is not a typesafe/jev id is refused", formula_text.replace('"typesafe/jev-1.14-20261014", ', '"openai/gpt-x", ', 1), "typesafe/jev-* ids")


EXPECTED_BODY = {
    "model": "~typesafe/jev-latest",
    "state": {
        "files_changed": ["env/.config/tmux/scripts/task-decide.py"],
        "summary": "Decision routing fixture.",
        "needs_decision": None,
        "risks": [],
    },
    "questions": {
        "touches_contract": {
            "type": "noul",
            "instructions": "Does this step change or depend on a cross-repo contract (C1-C5 in AGENTS.md): a file, path, payload, or name that another repo reads? (state: files_changed, summary)",
            "criteria": {"true": "changes or relies on a contract file, path, payload, or name", "false": "internal to one repo, or research only"},
        },
        "needs_user": {
            "type": "noul",
            "instructions": "Must the user decide or approve something before the next step, including any privileged request (deploy, install, merge, push)? (state: needs_decision, risks)",
            "criteria": {"true": "a decision, approval, or privileged request is pending", "false": "no decision pending; the next step can proceed"},
        },
        "next_owner": {
            "type": "choice",
            "instructions": "Which role should act next? (state: needs_decision, summary)",
            "criteria": {
                "worker": "a repo worker continues or fixes its step",
                "researcher": "external facts or context repos are needed",
                "orchestrator": "review, plan, contract, or privileged step",
                "none": "no next step",
            },
        },
    },
    "provider": {"only": ["typesafe"], "allow_fallbacks": False, "zdr": True, "data_collection": "deny"},
}


def check_routes(home, task):
    # Continue: one request, the same body as the dry run, and the record.
    report = write_report(task)
    mock(answer())
    code, out, _ = decide_cli(report, home)
    expect("continue exits 0", code, 0)
    if not out.startswith("route=continue step=12c record="):
        fail(f"one-line stdout was {out!r}")
    passed("continue prints the one-line summary")
    expect("one request, with the bearer key", (len(Mock.seen), Mock.seen[0][0]), (1, f"Bearer {KEY}"))
    expect("the request body is the dry-run body", Mock.seen[0][1], EXPECTED_BODY)
    record = read_record(task)
    expect("record route, model, provider", (record["route"], record["model"], record["provider"]), ("continue", GOOD_MODEL, "TypeSafe"))
    expect("record cost is kept from usage", record["usage"]["cost"], 0.00004)

    report = write_report(task, checks=[{"cmd": "shellcheck task-decide.py", "exit": 1}])
    mock(answer())
    code, _, _ = decide_cli(report, home, env={})
    expect("a failing check escalates with no key and no request", (code, len(Mock.seen)), (10, 0))
    expect("the failing-check record says why", read_record(task)["reason"].startswith("checks failed: shellcheck task-decide.py exit 1"), True)

    report = write_report(task)
    cases = [
        ({"p_user": 0.9}, 11, "ask_user", "a pending user decision asks the user"),
        ({"p_contract": 0.5}, 10, "escalate", "a noul inside the band escalates"),
        ({"p_owner": 0.3}, 10, "escalate", "a choice below min_confidence escalates"),
        ({"owner": "researcher"}, 10, "escalate", "researcher as next owner escalates"),
    ]
    for kwargs, want_code, want_route, label in cases:
        mock(answer(**kwargs))
        code, out, _ = decide_cli(report, home)
        expect(label, (code, read_record(task)["route"]), (want_code, want_route))

    mock(answer(p_user=0.1))
    needs = write_report(task, needs="Please push the branch and merge it into main.")
    code, _, _ = decide_cli(needs, home)
    expect("a privileged word in needs_decision asks the user even when Jev says no", code, 11)
    expect("the reason names the words", "privileged request in needs_decision: merge, push" in read_record(task)["reason"], True)

    report = write_report(task)
    mock(answer())
    code, out, _ = decide_cli(report, home, "--json")
    expect("--json prints the record", (code, json.loads(out)["route"]), (0, "continue"))


def check_refusals(home, task):
    report = write_report(task)
    refusals = [
        ("a non-typesafe model is refused", answer(model="openai/gpt-x"), 10, "not a typesafe/jev-* id", "openai/gpt-x"),
        ("a typesafe model off the ZDR list is refused", answer(model="typesafe/jev-1.12-20250101"), 10, "not on the ZDR list", "typesafe/jev-1.12-20250101"),
        ("a provider other than TypeSafe is refused", answer(provider="OpenRouter"), 10, "not TypeSafe", GOOD_MODEL),
        ("a noul given as text is refused", (200, {**answer()[1], "answers": {**answer()[1]["answers"], "needs_user": {"type": "noul", "noul": "high"}}}), 10, "bad noul value for needs_user", GOOD_MODEL),
    ]
    for label, reply, want_code, fragment, want_model in refusals:
        mock(reply)
        code, _, _ = decide_cli(report, home)
        record = read_record(task)
        expect(label, (code, fragment in record["reason"], record["model"]), (want_code, True, want_model))

    mock((503, {}), (503, {}), (503, {}))
    code, _, _ = decide_cli(report, home)
    record = read_record(task)
    expect("503 three times is exit 20, with three attempts", (code, len(Mock.seen), record["route"]), (20, 3, "escalate"))
    expect("the reason names the status", record["reason"], "decision service unavailable: HTTP 503 after 3 attempts")

    mock((429, {}), answer())
    code, _, _ = decide_cli(report, home)
    expect("a 429 then success retries and continues", (code, len(Mock.seen)), (0, 2))

    mock((401, {"error": {"message": f"invalid key {KEY}"}}))
    code, out, err = decide_cli(report, home)
    expect("a 401 is not retried and exits 20", (code, len(Mock.seen), read_record(task)["reason"]), (20, 1, "decision service unavailable: HTTP 401"))
    expect("the 401 body that echoes the key does not reach the output", KEY in out + err, False)


def check_keys(home, task):
    report = write_report(task)

    sentinel_key(home, 0o600)
    mock(answer())
    code, _, err = decide_cli(report, home, env={"TASK_DECIDE_LIVE": "1"})
    expect("no TASK_ROLE is exit 2 and the key file is not opened", (code, len(Mock.seen), "TASK_ROLE" in err), (2, 0, True))
    code, _, err = decide_cli(report, home, env={"TASK_ROLE": "worker", "TASK_DECIDE_LIVE": "1"})
    expect("TASK_ROLE=worker is exit 2 and the key file is not opened", (code, len(Mock.seen), "orchestrator only" in err), (2, 0, True))
    code, _, err = decide_cli(report, home, env={"TASK_ROLE": "orchestrator"})
    expect("a missing opt-in is exit 2 and the key file is not opened", (code, len(Mock.seen), "no live opt-in" in err), (2, 0, True))

    sentinel_key(home, 0o644)
    code, _, err = decide_cli(report, home)
    expect("a 644 key file is exit 2 and is not opened", (code, len(Mock.seen), "chmod 600" in err), (2, 0, True))

    key_path(home).unlink()
    code, _, err = decide_cli(report, home, env={**LIVE, "OPENROUTER_API_KEY": KEY})
    expect("an env key does not replace the key file: exit 2, no request", (code, len(Mock.seen), "no key file" in err), (2, 0, True))

    write_key(home, "# no key here\n")
    code, _, err = decide_cli(report, home)
    expect("a key file without the key line is exit 2", (code, "has no OPENROUTER_API_KEY line" in err), (2, True))

    write_key(home, KEY_LINE, 0o644)
    mock(answer())
    code, _, err = decide_cli(report, home)
    expect("a regular 644 key file is exit 2, with no request", (code, len(Mock.seen)), (2, 0))

    write_key(home, KEY_LINE)
    mock(answer())
    code, _, _ = decide_cli(report, home)
    expect("a 600 key file is used", (code, Mock.seen[0][0]), (0, f"Bearer {KEY}"))


def check_refused_inputs(tmp, home, task):
    report = write_report(task)
    valid = report.read_text(encoding="utf-8")
    expect("a --step that differs from the report is exit 3", decide_cli(report, home, step="99")[0], 3)
    expect("a --model off the formula's list is exit 3", decide_cli(report, home, "--model", "typesafe/jev-9")[0], 3)
    expect("--provider typesafe is exit 2 for now", decide_cli(report, home, "--provider", "typesafe")[0], 2)
    expect("no arguments is exit 2", run_cli([str(CLI)], home)[0], 2)
    bad_sha = write_report(tmp / "bad", head_sha="XYZ")
    expect("a report that fails the C4 schema is exit 3", decide_cli(bad_sha, home)[0], 3)
    elsewhere = tmp / "elsewhere" / "dotfiles" / "12c.json"
    elsewhere.parent.mkdir(parents=True)
    elsewhere.write_text(valid, encoding="utf-8")
    expect("a report outside reports/<agent>/ is exit 3", decide_cli(elsewhere, home)[0], 3)


def check_probe(tmp, home):
    formula = DD.load_formula(FORMULA)
    questions = {q["key"]: {"type": q["type"], "instructions": q["instructions"], "criteria": q["criteria"]} for q in DD.questions_of(formula)}
    clean = {"id": "clean", "ambiguous": False, "report": json.loads(write_report(tmp / "p1").read_text()),
             "questions": questions, "expected": {"touches_contract": False, "needs_user": False, "next_owner": "worker"}, "expected_route_in_code": None, "rationale": "fixture"}
    failing = {"id": "failing", "ambiguous": False, "report": json.loads(write_report(tmp / "p2", checks=[{"cmd": "x", "exit": 2}]).read_text()),
               "questions": questions, "expected": None, "expected_route_in_code": "escalate", "rationale": "fixture"}
    cases = tmp / "cases.jsonl"
    cases.write_text("\n".join(json.dumps(c) for c in (clean, failing)) + "\n", encoding="utf-8")

    def probe(*extra, env={}):
        return run_cli([str(PROBE), "--cases", str(cases), *extra], home, env)

    code, out, _ = probe()
    expect("the probe dry run exits 0 and builds one request", (code, "dry run: 2 cases, 1 requests built" in out, "1 routed in code" in out), (0, True, True))

    wrong = dict(failing, expected_route_in_code="ask_user")
    cases.write_text("\n".join(json.dumps(c) for c in (clean, wrong)) + "\n", encoding="utf-8")
    code, out, _ = probe()
    expect("a code route that differs from the case is reported and exits 1", (code, "code route escalate, case expects ask_user" in out), (1, True))
    cases.write_text("\n".join(json.dumps(c) for c in (clean, failing)) + "\n", encoding="utf-8")

    mock(answer(), answer(p_user=0.9))
    code, out, _ = probe("--live", "--runs", "2", env=LIVE)
    expect("the probe live run exits 0", code, 0)
    expect("live makes one call per run for the Jev case, none for the code case", len(Mock.seen), 2)
    for label, fragment in [
        ("the live summary counts calls and routes", "live: 2 calls over 1 cases; 1 routed in code (not called)"),
        ("the live summary names the resolved model", f"models seen: {GOOD_MODEL} (2)"),
        ("the live summary has the per-question block", "touches_contract (noul)"),
        ("the live summary has latency and cost", "latency: p50"),
        ("the live summary totals cost", "cost: $0.000080 (2 calls with usage.cost, 0 without)"),
    ]:
        expect(label, fragment in out, True)
    sentinel_key(home, 0o600)
    mock(answer())
    code, _, err = probe("--live", env={"TASK_DECIDE_LIVE": "1"})
    expect("the probe live run without TASK_ROLE is exit 2 and the key file is not opened", (code, len(Mock.seen), "TASK_ROLE" in err), (2, 0, True))
    sentinel_key(home, 0o644)
    code, _, err = probe("--live", env=LIVE)
    expect("the probe live run with a 644 key file is exit 2 and does not open it", (code, len(Mock.seen), "chmod 600" in err), (2, 0, True))
    key_path(home).unlink()
    code, _, err = probe("--live", env=LIVE)
    expect("the probe live run without a key file is exit 2", (code, "no key file" in err), (2, True))
    write_key(home, KEY_LINE)


def main():
    tmp = Path(tempfile.mkdtemp(prefix="task-decide-"))
    try:
        home = tmp / "home"
        task = tmp / "tasks" / "fixture"
        home.mkdir()
        write_key(home, KEY_LINE)
        check_formula_rules(tmp, FORMULA.read_text(encoding="utf-8"))
        formula = DD.load_formula(FORMULA)
        expect("the shipped formula loads", formula["formula"], "worker-step")

        report = write_report(task)
        mock(answer())
        code, out, _ = run_cli([str(CLI), "--formula", str(FORMULA), "--report", str(report), "--step", "12c", "--dry-run"], home, env={})
        expect("the dry run exits 0", code, 0)
        expect("the dry-run body is the snapshot", json.loads(out), EXPECTED_BODY)
        expect("the dry run made no request", len(Mock.seen), 0)

        check_routes(home, task)
        check_refusals(home, task)
        check_keys(home, task)
        check_refused_inputs(tmp, home, task)
        check_probe(tmp, home)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        SERVER.shutdown()
    print("PASS: all task-decide and jev-probe checks")


if __name__ == "__main__":
    main()
