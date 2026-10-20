#!/usr/bin/env python3
"""Offline checks for task-decide.py and jev-probe.py.

Runs both against a local mock of the decisions endpoint, so there is no network
and no real key. Covers the dry-run request body, every exit code, the ZDR and
model refusals, key handling, retries, the safety rules, the strict-continue gate
at its boundaries, and the probe's dry run, live run, --save and --replay. Checks
that the key never appears in any output or record. Writes only inside a
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
# The defaults that shipped in formula v2. A test fails if one is dropped without a change here.
DEFAULT_PATHS = {
    "**/task-roles/*.json": "env/.config/tmux/scripts/task-roles/worker.mcp.json",
    "**/task-roles/*.md": "env/.config/tmux/scripts/task-roles/worker.md",
    "**/*settings*.json": "env/.config/tmux/scripts/app-settings.json",
    "**/dotfiles.manifest": "dotfiles.manifest",
    "**/scripts/envctl": "scripts/envctl",
    "**/apply.sh": "scripts/apply.sh",
    "**/*deploy*": "scripts/deploy-live.sh",
    "**/*.schema.json": "env/x/report.schema.json",
}
DEFAULT_KEYWORDS = ["deploy", "push", "merge", "install", "sudo", "prune", "delet", "contract", "schema", "secret", "key", "credential", "permission"]


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


def answer(p_contract=0.1, p_user=0.02, owner="orchestrator", p_owner=0.9, model=GOOD_MODEL, provider="TypeSafe"):
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


def write_report(root, step="12e", agent="worker-dotfiles", checks=None, needs=None, **changes):
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
    environ.update({"HOME": str(home), "TASK_DECIDE_ENDPOINT": URL, "PYTHONDONTWRITEBYTECODE": "1"})
    environ.update(env or {})
    try:
        proc = subprocess.run([sys.executable, "-I", *args], env=environ, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(f"{Path(args[0]).name} did not return: it opened the key file, which a refusal must not do")
    if KEY in proc.stdout + proc.stderr:
        fail(f"the key was printed by {Path(args[0]).name}")
    return proc.returncode, proc.stdout, proc.stderr


def decide_cli(report, home, *extra, env=LIVE, step="12e"):
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


def read_record(task, agent="worker-dotfiles", step="12e"):
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
    expect_invalid(tmp, "formula with an unknown key is refused", formula_text.replace("version = 2", "version = 2\nsurprise = true", 1), "unknown key surprise")
    expect_invalid(tmp, "never list without push is refused", formula_text.replace('"merge", "push", ', '"merge", ', 1), "must list merge, push")
    expect_invalid(tmp, "a gate threshold above 1 is refused", formula_text.replace("continue_owner_min = 0.80", "continue_owner_min = 1.5", 1), "gate.continue_owner_min")
    expect_invalid(tmp, "a gate table missing a bound is refused", formula_text.replace("continue_owner_min = 0.80", "", 1), "gate.continue_owner_min")
    expect_invalid(tmp, "the removed band field is refused", formula_text.replace('reads = ["files_changed", "summary"]', 'reads = ["files_changed", "summary"]\nband = [0.35, 0.65]', 1), "unknown key band")
    expect_invalid(tmp, "a choice without expect is refused", formula_text.replace('expect = "orchestrator"', "", 1), "expect: one of the criteria")
    expect_invalid(tmp, "noul criteria without false is refused", formula_text.replace('false = "internal to one repo, or research only"', 'other = "x"', 1), "exactly true and false")
    expect_invalid(tmp, "instructions that do not name a read field are refused", formula_text.replace("(state: files_changed, summary)", "", 1), "must name files_changed")
    expect_invalid(tmp, "a model that is not a typesafe/jev id is refused", formula_text.replace('"typesafe/jev-1.14-20261014", ', '"openai/gpt-x", ', 1), "typesafe/jev-* ids")
    expect_invalid(tmp, "a question that is not one of the three is refused", formula_text.replace('key = "next_owner"', 'key = "owner_x"', 1), "touches_contract, needs_user or next_owner")
    expect_invalid(tmp, "a path glob with ** inside a name is refused", formula_text.replace('"**/*.schema.json"', '"a**b"', 1), "ask_user_paths")
    expect_invalid(tmp, "a keyword with digits is refused", formula_text.replace('"prune"', '"pr1une"', 1), "ask_user_keywords")
    expect_invalid(tmp, "a formula without a safety table is refused", formula_text.replace("[safety]", "[safety_x]", 1), "unknown key safety_x")


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
    if not out.startswith("route=continue step=12e record="):
        fail(f"one-line stdout was {out!r}")
    passed("continue prints the one-line summary")
    expect("one request, with the bearer key", (len(Mock.seen), Mock.seen[0][0]), (1, f"Bearer {KEY}"))
    expect("the request body is the dry-run body", Mock.seen[0][1], EXPECTED_BODY)
    record = read_record(task)
    expect("record route, rule, model, provider", (record["route"], record["rule"], record["model"], record["provider"]), ("continue", "jev", GOOD_MODEL, "TypeSafe"))
    expect("record cost is kept from usage", record["usage"]["cost"], 0.00004)

    report = write_report(task, checks=[{"cmd": "shellcheck task-decide.py", "exit": 1}])
    mock(answer())
    code, _, _ = decide_cli(report, home, env={})
    expect("a failing check escalates with no key and no request", (code, len(Mock.seen)), (10, 0))
    expect("the failing-check record says why", read_record(task)["reason"].startswith("checks failed: shellcheck task-decide.py exit 1"), True)
    expect("the failing-check record names its rule", read_record(task)["rule"], "code-check")

    report = write_report(task)
    cases = [
        ({"p_user": 0.9}, 11, "ask_user", "a pending user decision asks the user"),
        ({"p_contract": 0.5}, 10, "escalate", "a touches_contract at 0.5 escalates"),
        ({"p_owner": 0.3}, 10, "escalate", "a low-confidence owner escalates"),
        ({"owner": "researcher"}, 10, "escalate", "researcher as next owner escalates"),
        ({"owner": "worker"}, 10, "escalate", "worker as next owner escalates"),
        ({"p_user": 0.2}, 10, "escalate", "a needs_user between the two bounds escalates"),
    ]
    for kwargs, want_code, want_route, label in cases:
        mock(answer(**kwargs))
        code, out, _ = decide_cli(report, home)
        expect(label, (code, read_record(task)["route"], read_record(task)["rule"]), (want_code, want_route, "jev"))

    report = write_report(task)
    mock(answer())
    code, out, _ = decide_cli(report, home, "--json")
    expect("--json prints the record", (code, json.loads(out)["route"]), (0, "continue"))


def check_safety(home, task, formula):
    """Each safety rule routes ask_user in code: no request, and the matching rule is recorded."""
    expect("the shipped paths are the defaults", set(formula["safety"]["ask_user_paths"]), set(DEFAULT_PATHS))
    expect("the shipped keywords are the defaults", set(formula["safety"]["ask_user_keywords"]), set(DEFAULT_KEYWORDS))
    for glob, sample in DEFAULT_PATHS.items():
        report = write_report(task, files_changed=[sample])
        mock(answer())
        code, _, _ = decide_cli(report, home)
        record = read_record(task)
        expect(f"{glob} routes ask_user with no request", (code, len(Mock.seen), record["rule"]), (11, 0, "code-safety"))
        expect(f"{glob} is named in the reason", f"{glob} matches {sample}" in record["reason"], True)

    for sample in ["docs/notes.md", "README.md", "env/x/task-roles/notes.txt"]:
        report = write_report(task, files_changed=[sample])
        mock(answer())
        code, _, _ = decide_cli(report, home)
        expect(f"{sample} is not a safety path", (code, len(Mock.seen)), (0, 1))

    for word in DEFAULT_KEYWORDS:
        report = write_report(task, risks=[f"Might {word.upper()} things."])
        mock(answer())
        code, _, _ = decide_cli(report, home)
        record = read_record(task)
        expect(f"keyword {word} in risks routes ask_user with no request", (code, len(Mock.seen), record["rule"]), (11, 0, "code-safety"))
    report = write_report(task, summary="The schema is touched.")
    mock(answer())
    code, _, _ = decide_cli(report, home)
    expect("a keyword in summary routes ask_user", (code, read_record(task)["reason"]), (11, "safety: keyword schema in summary"))
    report = write_report(task, risks=["Someone may be deleting the old files."])
    mock(answer())
    code, _, _ = decide_cli(report, home)
    expect("a prefix keyword (delet) matches deleting", code, 11)
    report = write_report(task, risks=["The monkey test passed."])
    mock(answer())
    code, _, _ = decide_cli(report, home)
    expect("a keyword inside a word does not match (monkey)", (code, len(Mock.seen)), (0, 1))

    report = write_report(task, needs="Please approve the next step.")
    mock(answer())
    code, _, _ = decide_cli(report, home)
    expect("any non-null needs_decision asks the user with no request", (code, len(Mock.seen), read_record(task)["reason"]), (11, 0, "safety: needs_decision is set"))

    report = write_report(task, checks=[{"cmd": "shellcheck task-decide.py", "exit": 1}], needs="Approve the push.")
    mock(answer())
    code, _, _ = decide_cli(report, home)
    expect("a failing check outranks a safety hit: escalate, not ask_user", (code, read_record(task)["rule"]), (10, "code-check"))


def check_gate(formula):
    """The strict-continue gate at its boundary values, on the answers the decision call returns."""
    cases = [
        ({}, "continue"),
        ({"p_user": 0.0, "p_contract": 0.0, "p_owner": 1.0}, "continue"),
        ({"p_user": 0.049}, "continue"),
        ({"p_user": 0.05}, "escalate"),
        ({"p_user": 0.11}, "escalate"),
        ({"p_user": 0.30}, "escalate"),
        ({"p_user": 0.49}, "escalate"),
        ({"p_user": 0.5}, "ask_user"),
        ({"p_user": 0.9}, "ask_user"),
        ({"p_contract": 0.199}, "continue"),
        ({"p_contract": 0.2}, "escalate"),
        ({"p_owner": 0.85}, "continue"),
        ({"p_owner": 0.84}, "escalate"),
        ({"owner": "researcher"}, "escalate"),
        ({"owner": "none"}, "escalate"),
        ({"owner": "worker"}, "escalate"),
        ({"owner": "orchestrator", "p_owner": 0.3}, "escalate"),
    ]
    for kwargs, want in cases:
        answers = answer(**kwargs)[1]["answers"]
        route, reason = DD.route_answers(formula, answers)
        expect(f"gate {kwargs or 'default'} routes {want}", route, want)
    route, reason = DD.route_answers(formula, answer(p_user=0.5)[1]["answers"])
    expect("the ask_user reason names the bound", "at or above 0.50" in reason, True)
    route, reason = DD.route_answers(formula, answer(p_user=0.1)[1]["answers"])
    expect("the escalate reason names the bound it missed", "needs_user not below 0.05" in reason, True)


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
    expect("a service failure is recorded with its rule", record["rule"], "service")

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
    elsewhere = tmp / "elsewhere" / "dotfiles" / "12e.json"
    elsewhere.parent.mkdir(parents=True)
    elsewhere.write_text(valid, encoding="utf-8")
    expect("a report outside reports/<agent>/ is exit 3", decide_cli(elsewhere, home)[0], 3)


def line_with(text, *parts):
    """True when one line of the output holds every part (the probe's columns are padded)."""
    return any(all(part in line for part in parts) for line in text.splitlines())


def probe_case(id, report, expected, route_in_code, ambiguous=False):
    questions = {q["key"]: {"type": q["type"], "instructions": q["instructions"], "criteria": q["criteria"]} for q in DD.questions_of(DD.load_formula(FORMULA))}
    return {"id": id, "ambiguous": ambiguous, "report": report, "questions": questions, "expected": expected, "expected_route_in_code": route_in_code, "rationale": "fixture"}


def check_probe(tmp, home):
    formula_questions = {"touches_contract": False, "needs_user": False, "next_owner": "orchestrator"}
    cases = [
        probe_case("clean", json.loads(write_report(tmp / "p1", files_changed=["README.md"]).read_text()), formula_questions, None),
        probe_case("failing", json.loads(write_report(tmp / "p2", checks=[{"cmd": "x", "exit": 2}]).read_text()), None, "escalate"),
        probe_case("decision", json.loads(write_report(tmp / "p3", needs="Approve the push.").read_text()),
                   {"touches_contract": False, "needs_user": True, "next_owner": "orchestrator"}, "ask_user"),
        probe_case("syn-03-vague-risk", json.loads(write_report(tmp / "p4", risks=["This might interact with the researcher clones, not sure."]).read_text()),
                   {"touches_contract": False, "needs_user": True, "next_owner": "orchestrator"}, None),
        probe_case("syn-04-contract-schema-changed", json.loads(write_report(tmp / "p5", files_changed=["env/x/report.schema.json"]).read_text()),
                   {"touches_contract": True, "needs_user": True, "next_owner": "orchestrator"}, "ask_user"),
        probe_case("syn-06-deploy-script-changed", json.loads(write_report(tmp / "p6", files_changed=["scripts/deploy-live.sh"]).read_text()),
                   {"touches_contract": False, "needs_user": True, "next_owner": "orchestrator"}, "ask_user"),
    ]
    cases_file = tmp / "cases.jsonl"

    def write_cases(items):
        cases_file.write_text("\n".join(json.dumps(c) for c in items) + "\n", encoding="utf-8")

    write_cases(cases)

    def probe(*extra, env={}):
        return run_cli([str(PROBE), "--cases", str(cases_file), *extra], home, env)

    code, out, _ = probe()
    expect("the probe dry run exits 0", code, 0)
    expect("the dry run counts the rules", "rule counts (cases): code-check 1, code-safety 3, jev 2" in out, True)
    expect("the dry run names the rule for syn-04", line_with(out, "syn-04-contract-schema-changed", "code-safety", "ask_user x1"), True)
    expect("the dry run says syn-03 is pending and two misses are caught in code", "12d misses caught: 2 of 3; syn-03-vague-risk pending" in out, True)

    write_cases([cases[0], dict(cases[1], expected_route_in_code="ask_user")])
    code, out, _ = probe()
    expect("a code route that differs from the case is reported and exits 1", (code, "code route escalate, case expects ask_user" in out), (1, True))
    write_cases(cases)

    mock(answer(), answer(), answer(p_user=0.11), answer(p_user=0.30), answer(p_user=0.17))
    saved = tmp / "saved.jsonl"
    code, live_out, _ = probe("--live", "--runs", "1", "--save", str(saved), env=LIVE)
    expect("the probe live run exits 0", code, 0)
    expect("live makes one call per measured case, none for the failing check", len(Mock.seen), 5)
    for label, fragment in [
        ("the live summary counts responses", "live: 5 responses over 5 cases; 1 cases checked in code (no call)"),
        ("the live summary names the resolved model", f"models seen: {GOOD_MODEL} (5)"),
        ("the live summary has the rule counts", "rule counts (cases): code-check 1, code-safety 3, jev 2"),
        ("the live run catches the three misses", "12d misses caught: 3 of 3; syn-03-vague-risk escalate via jev; syn-04-contract-schema-changed ask_user via code-safety; syn-06-deploy-script-changed ask_user via code-safety"),
        ("no unsafe continue", "unsafe continues: 0"),
        ("the summary has the per-question block", "touches_contract (noul, strict"),
        ("the summary has latency and cost", "latency: p50"),
        ("the summary totals cost", "cost: $0.000200 (5 responses with usage.cost, 0 without)"),
    ]:
        expect(label, fragment in live_out, True)
    expect("the live table names syn-03 with its Jev route", line_with(live_out, "syn-03-vague-risk", "jev", "escalate x1"), True)
    expect("--save wrote one line per response", len(saved.read_text(encoding="utf-8").splitlines()), 5)
    expect("the saved responses hold no key", KEY in saved.read_text(encoding="utf-8"), False)

    calls_before = len(Mock.seen)
    code, replay_out, _ = probe("--replay", str(saved))
    expect("--replay exits 0 with no request", (code, len(Mock.seen)), (0, calls_before))
    expect("--replay scores the same as the live run", replay_out.split("\n")[1:], live_out.split("\n")[1:])

    partial = tmp / "partial.jsonl"
    partial.write_text("".join(line + "\n" for line in saved.read_text(encoding="utf-8").splitlines()[:2]), encoding="utf-8")
    code, _, err = probe("--replay", str(partial))
    expect("a replay that lacks a measured case is exit 3", (code, "replay has no responses for" in err), (3, True))
    expect("--save without --live is exit 2", probe("--save", str(tmp / "x.jsonl"))[0], 2)
    expect("--live with --replay is exit 2", probe("--live", "--replay", str(saved), env=LIVE)[0], 2)

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


def check_glob():
    """`**` is any depth only as a whole segment; inside a name it is one `*`."""
    expect("glob: a/** matches below a", bool(DD.glob_regex("a/**").match("a/x/y")), True)
    expect("glob: a/** does not match a2", bool(DD.glob_regex("a/**").match("a2")), False)
    expect("glob: a** stays one segment", bool(DD.glob_regex("a**").match("a/b")), False)
    expect("glob: a** matches within a name", bool(DD.glob_regex("a**").match("ab")), True)
    expect("glob: a**/b stays one segment", bool(DD.glob_regex("a**/b").match("ax/y/b")), False)
    expect("glob: **/x.md matches any depth", bool(DD.glob_regex("**/x.md").match("d/e/x.md")), True)


def main():
    tmp = Path(tempfile.mkdtemp(prefix="task-decide-"))
    try:
        home = tmp / "home"
        task = tmp / "tasks" / "fixture"
        home.mkdir()
        write_key(home, KEY_LINE)
        formula_text = FORMULA.read_text(encoding="utf-8")
        check_formula_rules(tmp, formula_text)
        formula = DD.load_formula(FORMULA)
        expect("the shipped formula loads", (formula["formula"], formula["version"]), ("worker-step", 2))

        report = write_report(task)
        mock(answer())
        code, out, _ = run_cli([str(CLI), "--formula", str(FORMULA), "--report", str(report), "--step", "12e", "--dry-run"], home, env={})
        expect("the dry run exits 0", code, 0)
        expect("the dry-run body is the snapshot", json.loads(out), EXPECTED_BODY)
        expect("the dry run made no request", len(Mock.seen), 0)

        check_routes(home, task)
        check_safety(home, task, formula)
        check_gate(formula)
        check_refusals(home, task)
        check_keys(home, task)
        check_refused_inputs(tmp, home, task)
        check_probe(tmp, home)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        SERVER.shutdown()
    check_glob()
    print("PASS: all task-decide and jev-probe checks")


if __name__ == "__main__":
    main()
