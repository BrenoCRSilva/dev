#!/usr/bin/env python3
"""Route a worker's step report with the Jev decision model (formula 7.2, CLI 7.3).

    task-decide --formula <path.toml> --report <report.json> --step <id>
                [--task-root <dir>] [--provider openrouter] [--model <id>]
                [--dry-run] [--json]

Code rules run first and make no request. A failing check routes "escalate" (rule
code-check). A non-null needs_decision, a files_changed path matching [safety]
ask_user_paths, or a keyword in risks[] or summary routes "ask_user" (rule
code-safety). Otherwise one OpenRouter Decisions request carries the formula's three
questions and the [gate] decides (rule jev): ask_user when needs_user p is at or above
ask_user_needs_user; continue only when needs_user p, touches_contract p and the
next_owner answer all clear their [gate] bounds; anything else escalates. The record
goes to <task-root>/decisions/<agent>/<step>.json and stdout gets one line:
"route=<route> step=<id> record=<path>".

Exit codes: 0 continue, 10 escalate, 11 ask_user, 20 decision service unavailable
(the caller treats it as escalate), 2 usage error, 3 invalid formula or report.
--dry-run prints the exact request body and makes no request; it exits 0, or the
route's code when a code rule routes the report.

A live request needs TASK_ROLE=orchestrator, TASK_DECIDE_LIVE=1 (the CLI's opt-in) and
~/.config/task-agents/openrouter.env at mode 600. Otherwise it exits 2 before the key
file is opened. Code-routed reports make no request, so they need none of this. The
key comes from OPENROUTER_API_KEY, else the key file's line. It is never printed or
recorded. TASK_DECIDE_ENDPOINT overrides the URL (tests only). Stdlib only.
"""
import argparse
import http.client
import importlib.util
import json
import os
import re
import stat
import sys
import time
import tomllib
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENDPOINT = "https://openrouter.ai/api/alpha/decisions"
ROUTES = {"continue": 0, "escalate": 10, "ask_user": 11}
SERVICE_EXIT = 20
USAGE_EXIT = 2
INVALID_EXIT = 3
ATTEMPTS = 3
RETRY_STATUS = {429, 502, 503, 524, 529}
TIMEOUT_S = 60
PRIVILEGED = ("merge", "push", "deploy", "install")
MODEL_ID = re.compile(r"typesafe/jev-[A-Za-z0-9._-]+")
QUESTION_TYPES = {"touches_contract": "noul", "needs_user": "noul", "next_owner": "choice"}
NOUL_KEYS = {"key", "type", "instructions", "criteria", "reads"}
CHOICE_KEYS = NOUL_KEYS | {"expect"}
SAFETY_KEYS = {"ask_user_paths", "ask_user_keywords"}
GATE_KEYS = ("ask_user_needs_user", "continue_needs_user_below", "continue_touches_contract_below", "continue_owner_min")
OWNER_EPS = 1e-9  # float rounding at the confidence floor


def _task_report():
    spec = importlib.util.spec_from_file_location("task_report", HERE / "task-report.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TASK_REPORT = _task_report()
REPORT_FIELDS = set(json.loads((HERE / "task-roles" / "report.schema.json").read_text(encoding="utf-8"))["properties"])


class Usage(Exception):
    """Bad flags, no key or an unsafe key file: exit 2."""


class Invalid(Exception):
    """Formula or report is invalid: exit 3."""


class ServiceError(Exception):
    """The decision call failed: exit 20."""


def endpoint():
    return os.environ.get("TASK_DECIDE_ENDPOINT", ENDPOINT)


def key_file():
    return Path.home() / ".config/task-agents/openrouter.env"


def live_gate(opt_in):
    """Refuses a live request before the key file is opened, unless every condition holds."""
    if os.environ.get("TASK_ROLE") != "orchestrator":
        raise Usage("live requests are for the orchestrator only: TASK_ROLE must be orchestrator")
    if not opt_in:
        raise Usage("no live opt-in: jev-probe needs --live; task-decide needs TASK_DECIDE_LIVE=1")
    path = key_file()
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError:
        raise Usage(f"no key file at {path}; a live request needs it at mode 600")
    if mode != 0o600:
        raise Usage(f"{path} must be mode 600 (it is {mode:o}); run chmod 600 on it")


def load_key():
    """Called only after live_gate passes: the env key, else the key file's line."""
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if key:
        return key
    for line in key_file().read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*(.*?)\s*", line)
        if match and match.group(1).strip("\"'"):
            return match.group(1).strip("\"'")
    raise Usage(f"{key_file()} has no OPENROUTER_API_KEY line")


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _exit_ok(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 255


def _only(table, allowed, where):
    for key in table:
        if key not in allowed:
            raise Invalid(f"{where}: unknown key {key}")


def _question(q):
    if not isinstance(q, dict):
        raise Invalid("steps.questions: each question is a table")
    key = q.get("key")
    where = f"question {key}"
    if not isinstance(key, str) or key not in QUESTION_TYPES:
        raise Invalid(f"question key {key!r}: touches_contract, needs_user or next_owner")
    if q.get("type") != QUESTION_TYPES[key]:
        raise Invalid(f"{where}.type: must be {QUESTION_TYPES[key]}")
    if not isinstance(q.get("instructions"), str) or not q["instructions"]:
        raise Invalid(f"{where}.instructions: required text")
    reads = q.get("reads")
    if not isinstance(reads, list) or not reads:
        raise Invalid(f"{where}.reads: list of report fields")
    for field in reads:
        if field not in REPORT_FIELDS:
            raise Invalid(f"{where}.reads: {field} is not a report field")
        if field not in q["instructions"]:
            raise Invalid(f"{where}.instructions must name {field}")
    criteria = q.get("criteria")
    if not isinstance(criteria, dict) or not all(isinstance(v, str) and v for v in criteria.values()):
        raise Invalid(f"{where}.criteria: text for each option")
    if q["type"] == "noul":
        _only(q, NOUL_KEYS, where)
        if set(criteria) != {"true", "false"}:
            raise Invalid(f"{where}.criteria: exactly true and false")
    else:
        _only(q, CHOICE_KEYS, where)
        if not 2 <= len(criteria) <= 255:
            raise Invalid(f"{where}.criteria: 2 to 255 options")
        if q.get("expect") not in criteria:
            raise Invalid(f"{where}.expect: one of the criteria")


def load_formula(path):
    try:
        formula = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise Invalid(f"formula {path}: {error}")
    _only(formula, {"formula", "version", "expect_exit", "never", "decision", "safety", "gate", "steps"}, "formula")
    if not isinstance(formula.get("formula"), str) or not isinstance(formula.get("version"), int):
        raise Invalid("formula: needs a name (formula) and an integer version")
    if not _exit_ok(formula.setdefault("expect_exit", 0)):
        raise Invalid("formula.expect_exit: integer 0-255")
    never = formula.get("never")
    if not isinstance(never, list) or not set(PRIVILEGED) <= set(never):
        raise Invalid(f"formula.never: must list {', '.join(PRIVILEGED)}")
    decision = formula.get("decision", {})
    _only(decision, {"provider", "model", "allowed_models", "zdr", "only"}, "decision")
    if decision.get("provider") != "openrouter":
        raise Invalid("decision.provider: must be openrouter")
    if not isinstance(decision.get("model"), str) or not decision["model"]:
        raise Invalid("decision.model: required")
    allowed = decision.get("allowed_models")
    if not isinstance(allowed, list) or not allowed or not all(isinstance(m, str) and MODEL_ID.fullmatch(m) for m in allowed):
        raise Invalid("decision.allowed_models: typesafe/jev-* ids")
    if decision.get("zdr") is not True or decision.get("only") != ["typesafe"]:
        raise Invalid('decision: zdr must be true and only = ["typesafe"]')
    safety = formula.get("safety")
    if not isinstance(safety, dict):
        raise Invalid("formula: needs a [safety] table")
    _only(safety, SAFETY_KEYS, "safety")
    paths = safety.get("ask_user_paths")
    if not isinstance(paths, list) or not paths or not all(
        isinstance(p, str) and p and not re.search(r"\*\*(?!/)", p) for p in paths
    ):
        raise Invalid("safety.ask_user_paths: globs; ** only as a whole folder (**/)")
    keywords = safety.get("ask_user_keywords")
    if not isinstance(keywords, list) or not keywords or not all(
        isinstance(w, str) and re.fullmatch(r"[a-z][a-z-]*", w) for w in keywords
    ):
        raise Invalid("safety.ask_user_keywords: lowercase words")
    # The privileged words are always keywords, whatever the list says.
    safety["ask_user_keywords"] = list(dict.fromkeys([*keywords, *never]))
    gate = formula.get("gate")
    if not isinstance(gate, dict):
        raise Invalid("formula: needs a [gate] table")
    _only(gate, set(GATE_KEYS), "gate")
    for key in GATE_KEYS:
        if not _number(gate.get(key)) or not 0 <= gate[key] <= 1:
            raise Invalid(f"gate.{key}: a number from 0 to 1")
    steps = formula.get("steps")
    if not isinstance(steps, list) or len(steps) != 1:
        raise Invalid("formula: exactly one [[steps]] entry in v1")
    step = steps[0]
    _only(step, {"id", "checks", "questions"}, "steps")
    if not isinstance(step.get("id"), str) or not step["id"]:
        raise Invalid("steps.id: required")
    for check in step.get("checks", []):
        _only(check, {"cmd", "expect_exit"}, "steps.checks")
        if not isinstance(check.get("cmd"), str) or not check["cmd"] or not _exit_ok(check.get("expect_exit")):
            raise Invalid("steps.checks: needs cmd and expect_exit 0-255")
    questions = step.get("questions")
    if not isinstance(questions, list):
        raise Invalid("steps.questions: touches_contract, needs_user and next_owner")
    for q in questions:
        _question(q)
    if sorted(q["key"] for q in questions) != sorted(QUESTION_TYPES):
        raise Invalid("steps.questions: exactly touches_contract, needs_user and next_owner")
    return formula


def questions_of(formula):
    return formula["steps"][0]["questions"]


def load_report(path, step):
    try:
        report = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Invalid(f"report {path}: cannot read as JSON: {error}")
    problems = TASK_REPORT.problems(report, Path(path))
    if problems:
        raise Invalid("; ".join(problems))
    if report["step"] != step:
        raise Invalid(f"report step {report['step']} is not --step {step}")
    return report


def code_route(formula, report):
    """Checks run in code. Returns the reason to escalate, or None when they pass."""
    wrong = [f"{c['cmd']} exit {c['exit']}" for c in report["checks"] if c["exit"] != formula["expect_exit"]]
    for required in formula["steps"][0].get("checks", []):
        got = [c["exit"] for c in report["checks"] if c["cmd"] == required["cmd"]]
        if not got:
            wrong.append(f"{required['cmd']} not run")
        elif got[-1] != required["expect_exit"]:
            wrong.append(f"{required['cmd']} exit {got[-1]} (want {required['expect_exit']})")
    if wrong:
        return ("checks failed: " + "; ".join(wrong))[:300]
    return None


def glob_regex(pattern):
    """'**/' matches any folders or none; '*' and '?' stay within one name."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def safety_hit(formula, report, keywords=True):
    """The first safety rule the report hits, as text, or None. keywords=False skips the keyword rule (the v2 dispatcher
    routes bare keywords to Opus itself, so the path and needs_decision rules are all that count here)."""
    safety = formula["safety"]
    if report["needs_decision"] is not None:
        return "needs_decision is set"
    for pattern in safety["ask_user_paths"]:
        regex = glob_regex(pattern)
        for path in report["files_changed"]:
            if regex.match(path):
                return f"{pattern} matches {path}"
    for field, texts in (("risks", report["risks"]), ("summary", [report["summary"]])):
        for word in safety["ask_user_keywords"] if keywords else []:
            pattern = rf"\b{re.escape(word)}\w*"
            if any(re.search(pattern, text, re.IGNORECASE) for text in texts):
                return f"keyword {word} in {field}"
    return None


def code_rule(formula, report, keywords=True):
    """The route code gives before any request: (route, rule, reason), or None."""
    failed = code_route(formula, report)
    if failed:
        return "escalate", "code-check", failed
    hit = safety_hit(formula, report, keywords)
    if hit:
        return "ask_user", "code-safety", f"safety: {hit}"
    return None


def build_request(formula, report, model):
    questions = questions_of(formula)
    state = {}
    for q in questions:
        for field in q["reads"]:
            state.setdefault(field, report[field])
    decision = formula["decision"]
    return {
        "model": model,
        "state": state,
        "questions": {
            q["key"]: {"type": q["type"], "instructions": q["instructions"], "criteria": q["criteria"]} for q in questions
        },
        "provider": {
            "only": decision["only"],
            "allow_fallbacks": False,
            "zdr": decision["zdr"],
            "data_collection": "deny",
        },
    }


def call(body, key, url, sleep=time.sleep):
    """POST the request. Retries 429 and 5xx-style errors; raises ServiceError."""
    data = json.dumps(body).encode("utf-8")
    failure = "no attempt"
    for attempt in range(ATTEMPTS):
        request = urllib.request.Request(
            url,
            data=data,
            method="POST",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_S) as reply:
                raw = reply.read()
        except urllib.error.HTTPError as error:
            if error.code not in RETRY_STATUS:
                raise ServiceError(f"HTTP {error.code}")
            failure = f"HTTP {error.code}"
        except (OSError, http.client.HTTPException) as error:
            failure = type(error).__name__
        else:
            try:
                response = json.loads(raw)
            except ValueError:
                raise ServiceError("response is not JSON")
            if not isinstance(response, dict):
                raise ServiceError("response is not an object")
            return response
        if attempt + 1 < ATTEMPTS:
            sleep(2**attempt)
    raise ServiceError(f"{failure} after {ATTEMPTS} attempts")


def response_problem(formula, response):
    """Why the response cannot be used, or None."""
    model = response.get("model")
    if not isinstance(model, str) or not MODEL_ID.fullmatch(model):
        return f"model {model!r} is not a typesafe/jev-* id"
    if model not in formula["decision"]["allowed_models"]:
        return f"model {model} is not on the ZDR list"
    if str(response.get("provider", "")).lower() != "typesafe":
        return f"provider {response.get('provider')!r} is not TypeSafe"
    answers = response.get("answers")
    if not isinstance(answers, dict):
        return "response has no answers"
    for q in questions_of(formula):
        answer = answers.get(q["key"])
        if not isinstance(answer, dict) or answer.get("type") != q["type"]:
            return f"no {q['type']} answer for {q['key']}"
        if q["type"] == "noul":
            if not _number(answer.get("noul")) or not 0 <= answer["noul"] <= 1:
                return f"bad noul value for {q['key']}"
        else:
            probs = answer.get("probabilities")
            if not isinstance(probs, dict) or any(not _number(probs.get(option)) for option in q["criteria"]):
                return f"bad probabilities for {q['key']}"
    return None


def route_answers(formula, answers):
    """The [gate] on Jev's answers. Returns (route, reason)."""
    gate = formula["gate"]
    owner = next(q for q in questions_of(formula) if q["key"] == "next_owner")
    p_user = answers["needs_user"]["noul"]
    p_contract = answers["touches_contract"]["noul"]
    probs = {option: answers["next_owner"]["probabilities"][option] for option in owner["criteria"]}
    best = max(probs, key=probs.get)
    n = len(probs)
    confidence = (probs[best] - 1 / n) / (1 - 1 / n)
    head = f"checks and safety clear; needs_user p={p_user:.3f}; touches_contract p={p_contract:.3f}; next_owner {best} (conf {confidence:.3f})"
    if p_user >= gate["ask_user_needs_user"]:
        return "ask_user", f"{head}; needs_user at or above {gate['ask_user_needs_user']:.2f}"
    misses = []
    if p_user >= gate["continue_needs_user_below"]:
        misses.append(f"needs_user not below {gate['continue_needs_user_below']:.2f}")
    if p_contract >= gate["continue_touches_contract_below"]:
        misses.append(f"touches_contract not below {gate['continue_touches_contract_below']:.2f}")
    if best != owner["expect"]:
        misses.append(f"next_owner is not {owner['expect']}")
    if confidence < gate["continue_owner_min"] - OWNER_EPS:
        misses.append(f"next_owner confidence below {gate['continue_owner_min']:.2f}")
    if misses:
        return "escalate", f"{head}; {'; '.join(misses)}"
    return "continue", head


def route_response(formula, response):
    """(route, reason) for a Jev response, after the response checks."""
    problem = response_problem(formula, response)
    if problem:
        return "escalate", problem
    return route_answers(formula, response["answers"])


def record(formula, report, route, rule, reason, response=None, answers=None):
    response = response or {}
    return {
        "step": report["step"],
        "formula": f"{formula['formula']}@{formula['version']}",
        "route": route,
        "rule": rule,
        "reason": reason,
        "model": response.get("model"),
        "provider": response.get("provider"),
        "answers": answers or {},
        "usage": response.get("usage"),
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def ask_jev(formula, report, model, *, opt_in, key_loader=load_key, url=None, sleep=time.sleep):
    """One decision request. Raises Usage before the key file is opened, ServiceError on failure."""
    live_gate(opt_in)
    body = build_request(formula, report, model)
    return call(body, key_loader(), url or endpoint(), sleep)


def decide(formula, report, *, model, opt_in, key_loader=load_key, url=None, sleep=time.sleep, keywords=True):
    """Returns (record, exit code). Makes at most one decision request, and none when a code rule routes."""
    hit = code_rule(formula, report, keywords)
    if hit:
        route, rule, reason = hit
        return record(formula, report, route, rule, reason), ROUTES[route]
    try:
        response = ask_jev(formula, report, model, opt_in=opt_in, key_loader=key_loader, url=url, sleep=sleep)
    except ServiceError as error:
        return record(formula, report, "escalate", "service", f"decision service unavailable: {error}"), SERVICE_EXIT
    route, reason = route_response(formula, response)
    answers = response["answers"] if isinstance(response.get("answers"), dict) else {}
    return record(formula, report, route, "jev", reason, response, answers), ROUTES[route]


def dry_run(formula, report, model):
    hit = code_rule(formula, report)
    if hit:
        route, rule, reason = hit
        print(f"route={route} step={report['step']} dry-run: {rule}: {reason}; no request")
        return ROUTES[route]
    print(json.dumps(build_request(formula, report, model), indent=2))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Route a worker step report with the Jev decision model.")
    parser.add_argument("--formula", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--step", required=True)
    parser.add_argument("--task-root", type=Path)
    parser.add_argument("--provider", choices=["openrouter", "typesafe"], default="openrouter")
    parser.add_argument("--model")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--no-keyword-rule", action="store_true",
                        help="skip the keyword safety rule (the v2 dispatcher routes keywords to Opus itself)")
    args = parser.parse_args(argv)
    try:
        if args.provider != "openrouter":
            raise Usage("--provider typesafe is not built yet; use openrouter")
        formula = load_formula(args.formula)
        model = args.model or formula["decision"]["model"]
        if model != formula["decision"]["model"] and model not in formula["decision"]["allowed_models"]:
            raise Invalid(f"model {model} is not on the formula's ZDR list")
        report = load_report(args.report, args.step)
        if args.dry_run:
            return dry_run(formula, report, model)
        result, code = decide(formula, report, model=model, opt_in=os.environ.get("TASK_DECIDE_LIVE") == "1",
                              keywords=not args.no_keyword_rule)
        root = args.task_root or args.report.resolve().parents[2]
        path = root / "decisions" / report["agent"] / f"{report['step']}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print(f"route={result['route']} step={report['step']} record={path}")
        return code
    except Usage as error:
        print(f"task-decide: {error}", file=sys.stderr)
        return USAGE_EXIT
    except Invalid as error:
        print(f"task-decide: {error}", file=sys.stderr)
        return INVALID_EXIT


if __name__ == "__main__":
    sys.exit(main())
