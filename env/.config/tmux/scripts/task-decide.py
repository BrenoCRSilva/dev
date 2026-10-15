#!/usr/bin/env python3
"""Route a worker's step report with the Jev decision model (formula 7.2, CLI 7.3).

    task-decide --formula <path.toml> --report <report.json> --step <id>
                [--task-root <dir>] [--provider openrouter] [--model <id>]
                [--dry-run] [--json]

The formula's checks run in code first; a failing check routes "escalate" with
no request. Otherwise one OpenRouter Decisions request carries all the formula's
questions, and the bands and route rules decide the route. The record goes to
<task-root>/decisions/<agent>/<step>.json and stdout gets one line:
"route=<route> step=<id> record=<path>".

Exit codes: 0 continue, 10 escalate, 11 ask_user, 20 decision service
unavailable (the caller treats it as escalate), 2 usage error, 3 invalid formula
or report. --dry-run prints the exact request body and makes no request; it
exits 0, or the route's code when a check fails.

The key comes from OPENROUTER_API_KEY, else ~/.config/task-agents/openrouter.env,
which must not be readable by group or others. It is never printed or recorded.
TASK_DECIDE_ENDPOINT overrides the URL (tests only). Stdlib only.
"""
import argparse
import http.client
import importlib.util
import json
import os
import re
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
PRECEDENCE = ["continue", "escalate", "ask_user"]
SERVICE_EXIT = 20
USAGE_EXIT = 2
INVALID_EXIT = 3
ATTEMPTS = 3
RETRY_STATUS = {429, 502, 503, 524, 529}
TIMEOUT_S = 60
PRIVILEGED = ("merge", "push", "deploy", "install")
MODEL_ID = re.compile(r"typesafe/jev-[A-Za-z0-9._-]+")
NOUL_KEYS = {"key", "type", "instructions", "criteria", "reads", "band", "route_if_true", "route_if_false"}
CHOICE_KEYS = {"key", "type", "instructions", "criteria", "reads", "min_confidence", "on_low_confidence", "routes"}


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


def load_key():
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if key:
        return key
    path = Path.home() / ".config/task-agents/openrouter.env"
    try:
        mode = path.stat().st_mode
    except OSError:
        raise Usage("no key: set OPENROUTER_API_KEY or create ~/.config/task-agents/openrouter.env (mode 600)")
    if mode & 0o077:
        raise Usage("~/.config/task-agents/openrouter.env is readable by group or others; run chmod 600 on it")
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*(.*?)\s*", line)
        if match and match.group(1).strip("\"'"):
            return match.group(1).strip("\"'")
    raise Usage("~/.config/task-agents/openrouter.env has no OPENROUTER_API_KEY line")


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _exit_ok(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 255


def _only(table, allowed, where):
    for key in table:
        if key not in allowed:
            raise Invalid(f"{where}: unknown key {key}")


def _route(value, where):
    if value not in ROUTES:
        raise Invalid(f"{where}: route must be one of {', '.join(ROUTES)}")


def _question(q):
    if not isinstance(q, dict):
        raise Invalid("steps.questions: each question is a table")
    key = q.get("key")
    where = f"question {key}"
    if not isinstance(key, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", key):
        raise Invalid(f"question key {key!r}: lowercase letters, digits and _")
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
    if q.get("type") == "noul":
        _only(q, NOUL_KEYS, where)
        if set(criteria) != {"true", "false"}:
            raise Invalid(f"{where}.criteria: exactly true and false")
        band = q.get("band")
        if band is not None and not (
            isinstance(band, list) and len(band) == 2 and all(_number(x) for x in band) and 0 <= band[0] < band[1] <= 1
        ):
            raise Invalid(f"{where}.band: [low, high] with 0 <= low < high <= 1")
        _route(q.get("route_if_true"), where)
        _route(q.get("route_if_false"), where)
    elif q.get("type") == "choice":
        _only(q, CHOICE_KEYS, where)
        if not 2 <= len(criteria) <= 255:
            raise Invalid(f"{where}.criteria: 2 to 255 options")
        confidence = q.get("min_confidence")
        if not _number(confidence) or not 0 <= confidence <= 1:
            raise Invalid(f"{where}.min_confidence: a number from 0 to 1")
        _route(q.get("on_low_confidence"), where)
        routes = q.get("routes")
        if not isinstance(routes, dict) or set(routes) != set(criteria):
            raise Invalid(f"{where}.routes: one route for each option")
        for route in routes.values():
            _route(route, where)
    else:
        raise Invalid(f"{where}.type: noul or choice")


def load_formula(path):
    try:
        formula = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise Invalid(f"formula {path}: {error}")
    _only(formula, {"formula", "version", "expect_exit", "never", "decision", "steps"}, "formula")
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
    if not isinstance(questions, list) or not questions:
        raise Invalid("steps.questions: at least one")
    for q in questions:
        _question(q)
    keys = [q["key"] for q in questions]
    if len(set(keys)) != len(keys):
        raise Invalid("steps.questions: duplicate key")
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


def route_answers(formula, report, answers):
    """Applies the bands, thresholds, route rules and never-words. Returns (route, reason)."""
    picks, parts = [], []
    for q in questions_of(formula):
        answer = answers[q["key"]]
        if q["type"] == "noul":
            p = answer["noul"]
            low, high = q.get("band", (0.5, 0.5))
            if low < p < high:
                picks.append("escalate")
                parts.append(f"{q['key']} abstains (p={p:.2f})")
            else:
                yes = p >= high
                picks.append(q["route_if_true"] if yes else q["route_if_false"])
                parts.append(f"{q['key']}={str(yes).lower()} (p={p:.2f})")
        else:
            probs = {option: answer["probabilities"][option] for option in q["criteria"]}
            n = len(probs)
            best = max(probs, key=probs.get)
            confidence = (probs[best] - 1 / n) / (1 - 1 / n)
            if confidence < q["min_confidence"]:
                picks.append(q["on_low_confidence"])
                parts.append(f"{q['key']} low confidence ({confidence:.2f})")
            else:
                picks.append(q["routes"][best])
                parts.append(f"{q['key']}={best} (conf {confidence:.2f})")
    text = report.get("needs_decision") or ""
    hits = [word for word in formula["never"] if re.search(rf"\b{re.escape(word)}\b", text, re.IGNORECASE)]
    if hits:
        picks.append("ask_user")
        parts.append(f"privileged request in needs_decision: {', '.join(hits)}")
    route = max(picks, key=PRECEDENCE.index, default="continue")
    return route, "checks ok; " + "; ".join(parts)


def record(formula, report, route, reason, response=None, answers=None):
    response = response or {}
    return {
        "step": report["step"],
        "formula": f"{formula['formula']}@{formula['version']}",
        "route": route,
        "reason": reason,
        "model": response.get("model"),
        "provider": response.get("provider"),
        "answers": answers or {},
        "usage": response.get("usage"),
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def decide(formula, report, *, model, key_loader=load_key, url=None, sleep=time.sleep):
    """Returns (record, exit code). Makes at most one decision request."""
    blocked = code_route(formula, report)
    if blocked:
        return record(formula, report, "escalate", blocked), ROUTES["escalate"]
    body = build_request(formula, report, model)
    try:
        response = call(body, key_loader(), url or endpoint(), sleep)
    except ServiceError as error:
        return record(formula, report, "escalate", f"decision service unavailable: {error}"), SERVICE_EXIT
    problem = response_problem(formula, response)
    if problem:
        route, reason = "escalate", problem
    else:
        route, reason = route_answers(formula, report, response["answers"])
    answers = response["answers"] if isinstance(response.get("answers"), dict) else {}
    return record(formula, report, route, reason, response, answers), ROUTES[route]


def dry_run(formula, report, model):
    blocked = code_route(formula, report)
    if blocked:
        print(f"route=escalate step={report['step']} dry-run: {blocked}; no request")
        return ROUTES["escalate"]
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
        result, code = decide(formula, report, model=model)
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
