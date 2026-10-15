#!/usr/bin/env python3
"""Run a Jev probe set through task-decide's rules and score the answers.

    jev-probe.py --cases <cases.jsonl> [--formula <worker-step.toml>]
                 [--live [--runs 3] [--save <file>]] [--replay <file>]

The default is a dry run: no network, no key. It prints each case's route and the rule
that gave it (code-check, code-safety or jev). --live sends each case whose checks pass
--runs times to task-decide's ask_jev() (the live gate applies: TASK_ROLE=orchestrator
and a mode 600 key file), including cases the safety rules route, so Jev is scored on
every labelled case. --save <file> writes the raw responses (JSONL) after a live run.
--replay <file> routes and scores those saved responses offline: no network, no key.
Cases that fail a check are never sent. Stdlib only.
"""
import argparse
import importlib.util
import json
import math
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "env/.config/tmux/scripts"
DEFAULT_FORMULA = SCRIPTS / "task-roles/formulas/worker-step.toml"
GROUPS = ("all", "clear", "ambiguous")
# The unsafe misses of the 12d live run: needs_user said no (p < 0.5) where the user was needed.
KNOWN_MISSES = ("syn-03-vague-risk", "syn-04-contract-schema-changed", "syn-06-deploy-script-changed")


def _load_decide():
    spec = importlib.util.spec_from_file_location("task_decide", SCRIPTS / "task-decide.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DD = _load_decide()


def load_cases(path, formula):
    cases = []
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            case = json.loads(line)
        except ValueError as error:
            raise DD.Invalid(f"{path}:{number}: {error}")
        for field in ("id", "ambiguous", "report", "questions", "expected", "expected_route_in_code"):
            if field not in case:
                raise DD.Invalid(f"{path}:{number}: missing {field}")
        problems = DD.TASK_REPORT.problems(case["report"])
        if problems:
            raise DD.Invalid(f"{case['id']}: {'; '.join(problems)}")
        # The formula's wording is what ships; the case must ask the same questions.
        for q in DD.questions_of(formula):
            asked = case["questions"].get(q["key"])
            if not asked or asked.get("type") != q["type"]:
                raise DD.Invalid(f"{case['id']}: no {q['type']} question {q['key']}")
        cases.append(case)
    return cases


def check_case(formula, case):
    """Returns a mismatch message when the case's labels or code-route expectation disagree with the code."""
    hit = DD.code_rule(formula, case["report"])
    checks_failed = hit is not None and hit[1] == "code-check"
    code = hit[0] if hit else None
    if (case["expected"] is None) != checks_failed:
        return f"{case['id']}: labels {'absent' if case['expected'] is None else 'present'} but checks {'fail' if checks_failed else 'pass'}"
    if code != case["expected_route_in_code"]:
        return f"{case['id']}: code route {code or 'none'}, case expects {case['expected_route_in_code'] or 'none'}"
    return None


def case_rule(formula, case):
    hit = DD.code_rule(formula, case["report"])
    return hit[1] if hit else "jev"


def load_replay(path):
    """Saved attempts by case id, in run order: each has response or error, and latency_s."""
    attempts = {}
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError as error:
            raise DD.Invalid(f"{path}:{number}: {error}")
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or ("response" in entry) == ("error" in entry):
            raise DD.Invalid(f"{path}:{number}: needs id and exactly one of response or error")
        attempts.setdefault(entry["id"], []).append(entry)
    return attempts


def save_attempts(path, attempts):
    lines = []
    for case_id, entries in attempts.items():
        for run, entry in enumerate(entries):
            lines.append(json.dumps({"id": case_id, "run": run, **entry}))
    Path(path).write_text("".join(line + "\n" for line in lines), encoding="utf-8")


def live_attempts(formula, case, runs):
    attempts = []
    for _ in range(runs):
        start = time.perf_counter()
        try:
            entry = {"response": DD.ask_jev(formula, case["report"], formula["decision"]["model"], opt_in=True, key_loader=DD.load_key, url=DD.endpoint())}
        except DD.ServiceError as error:
            entry = {"error": str(error)}
        entry["latency_s"] = time.perf_counter() - start
        attempts.append(entry)
    return attempts


def rows_for(formula, case, attempts):
    """One row per attempt. A case that fails a check gets one row and no attempt."""
    hit = DD.code_rule(formula, case["report"])
    if hit and hit[1] == "code-check":
        return [{"case": case, "run": 0, "route": hit[0], "rule": hit[1], "reason": hit[2], "answers": None, "called": False, "latency_s": None, "usage": None, "model": None}]
    rows = []
    for run, entry in enumerate(attempts):
        response = entry.get("response") or {}
        if hit:
            route, rule, reason = hit
        elif "error" in entry:
            route, rule, reason = "escalate", "service", f"decision service unavailable: {entry['error']}"
        else:
            route, reason = DD.route_response(formula, response)
            rule = "jev"
        answers = response.get("answers")
        rows.append({
            "case": case, "run": run, "route": route, "rule": rule, "reason": reason,
            "answers": answers if isinstance(answers, dict) else None, "called": True,
            "latency_s": entry.get("latency_s"), "usage": response.get("usage"), "model": response.get("model"),
        })
    return rows


def dry_rows(formula, case):
    hit = DD.code_rule(formula, case["report"])
    if hit:
        route, rule, reason = hit
    else:
        route, rule, reason = None, "jev", "needs Jev answers (--live or --replay)"
    return [{"case": case, "run": 0, "route": route, "rule": rule, "reason": reason, "answers": None, "called": False, "latency_s": None, "usage": None, "model": None}]


def _valid(answer, q):
    if not isinstance(answer, dict):
        return False
    if q["type"] == "noul":
        return isinstance(answer.get("noul"), (int, float))
    probs = answer.get("probabilities")
    return isinstance(probs, dict) and all(isinstance(probs.get(option), (int, float)) for option in q["criteria"])


def score_question(q, rows):
    groups = {g: {"n": 0, "right": 0, "wrong": []} for g in GROUPS}
    sides = {}
    for row in rows:
        answer = (row["answers"] or {}).get(q["key"])
        if not _valid(answer, q):
            continue
        case = row["case"]
        label = case["expected"][q["key"]]
        if q["type"] == "noul":
            pred = answer["noul"] >= 0.5
            detail = f"p={answer['noul']:.3f}"
        else:
            probs = {option: answer["probabilities"][option] for option in q["criteria"]}
            pred = max(probs, key=probs.get)
            detail = f"{pred} {probs[pred]:.3f}"
        sides.setdefault(case["id"], set()).add(pred)
        for group in ("all", "ambiguous" if case["ambiguous"] else "clear"):
            g = groups[group]
            g["n"] += 1
            g["right"] += pred == label
            if pred != label:
                g["wrong"].append(f"{case['id']}#{row['run']} {detail}")
    return groups, sides


def print_question(q, rows):
    groups, sides = score_question(q, rows)
    print(f"{q['key']} ({q['type']}, strict: p >= 0.5 for noul)")
    for group in GROUPS:
        g = groups[group]
        if g["n"]:
            print(f"  {group:<9} n={g['n']} right {g['right']}/{g['n']} ({g['right'] / g['n']:.0%})")
    for wrong in groups["all"]["wrong"]:
        print(f"    wrong: {wrong}")
    unstable = sorted(case_id for case_id, seen in sides.items() if len(seen) > 1)
    print(f"  unstable: {', '.join(unstable) if unstable else 'none'}")


def print_routes(formula, cases, rows):
    by_case = {}
    for row in rows:
        by_case.setdefault(row["case"]["id"], []).append(row)
    print("routes by case (rule, then routes over the runs):")
    for case in cases:
        case_rows = by_case.get(case["id"], [])
        counts = Counter(row["route"] or "pending" for row in case_rows)
        text = ", ".join(f"{route} x{n}" for route, n in counts.items())
        print(f"  {case['id']:<40} {case_rule(formula, case):<13} {text}")


def print_known_misses(rows):
    parts, caught = [], 0
    for case_id in KNOWN_MISSES:
        case_rows = [row for row in rows if row["case"]["id"] == case_id]
        if not case_rows:
            parts.append(f"{case_id} not in cases")
            continue
        routes = {row["route"] for row in case_rows}
        rules = sorted({row["rule"] for row in case_rows})
        if None in routes:
            parts.append(f"{case_id} pending (needs --replay or --live)")
            continue
        caught += all(route != "continue" for route in routes)
        parts.append(f"{case_id} {'/'.join(sorted(routes))} via {'/'.join(rules)}")
    print(f"12d misses caught: {caught} of {len(KNOWN_MISSES)}; " + "; ".join(parts))


def print_summary(formula, cases, rows):
    counts = Counter(case_rule(formula, case) for case in cases)
    print("rule counts (cases): " + ", ".join(f"{rule} {counts[rule]}" for rule in ("code-check", "code-safety", "jev")))
    print_routes(formula, cases, rows)
    print_known_misses(rows)
    unsafe = []
    for row in rows:
        label = row["case"]["expected"] or {}
        if row["route"] == "continue" and (label.get("needs_user") or label.get("touches_contract")):
            unsafe.append(f"{row['case']['id']}#{row['run']}")
    print(f"unsafe continues: {len(unsafe)}" + (f" ({', '.join(unsafe)})" if unsafe else ""))


def print_report(formula, cases, rows, mode):
    called = [row for row in rows if row["called"]]
    print(f"{mode}: {len(called)} responses over {len({row['case']['id'] for row in called})} cases; {sum(1 for c in cases if c['expected'] is None)} cases checked in code (no call)")
    models = Counter(row["model"] for row in called)
    print("models seen: " + (", ".join(f"{m} ({n})" for m, n in models.items()) or "none"))
    print_summary(formula, cases, rows)
    for q in DD.questions_of(formula):
        print_question(q, rows)
    costs = [row["usage"]["cost"] for row in called if isinstance(row["usage"], dict) and _is_cost(row["usage"].get("cost"))]
    print(f"cost: ${sum(costs):.6f} ({len(costs)} responses with usage.cost, {len(called) - len(costs)} without)")
    seconds = [row["latency_s"] for row in called if row["latency_s"] is not None]
    if seconds:
        print(f"latency: p50 {percentile(seconds, 50) * 1000:.0f} ms, p95 {percentile(seconds, 95) * 1000:.0f} ms")


def dry_run(formula, cases):
    rows = [row for case in cases for row in dry_rows(formula, case)]
    measured = [case for case in cases if case["expected"] is not None]
    bytes_total = sum(len(json.dumps(DD.build_request(formula, case["report"], formula["decision"]["model"]))) for case in measured)
    print(f"dry run: {len(cases)} cases; {len(measured)} requests built ({bytes_total} bytes), of which "
          f"{sum(1 for case in measured if case_rule(formula, case) == 'code-safety')} are routed by code-safety and only measured; no network, no key")
    print_summary(formula, cases, rows)
    return rows


def percentile(values, pct):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(pct / 100 * len(ordered)) - 1)]


def _is_cost(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Run a Jev probe set through task-decide's rules and score it.")
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--formula", type=Path, default=DEFAULT_FORMULA)
    parser.add_argument("--live", action="store_true", help="send the real requests (needs the key)")
    parser.add_argument("--runs", type=int, default=3, help="responses per case with --live")
    parser.add_argument("--save", type=Path, help="with --live: write the raw responses to this JSONL file")
    parser.add_argument("--replay", type=Path, help="score responses saved by --save, offline")
    args = parser.parse_args(argv)
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    if args.live and args.replay:
        parser.error("--live and --replay are exclusive")
    if args.save and not args.live:
        parser.error("--save needs --live")
    try:
        formula = DD.load_formula(args.formula)
        cases = load_cases(args.cases, formula)
        mismatches = [m for m in (check_case(formula, case) for case in cases) if m]
        measured = [case for case in cases if case["expected"] is not None]
        if args.replay:
            saved = load_replay(args.replay)
            missing = [case["id"] for case in measured if case["id"] not in saved]
            if missing:
                raise DD.Invalid(f"replay has no responses for {', '.join(missing)}")
            attempts = {case["id"]: saved[case["id"]] for case in measured}
        elif args.live:
            attempts = {case["id"]: live_attempts(formula, case, args.runs) for case in measured}
            if args.save:
                save_attempts(args.save, attempts)
        else:
            dry_run(formula, cases)
            for mismatch in mismatches:
                print(f"mismatch: {mismatch}")
            return 1 if mismatches else 0
        rows = [row for case in cases for row in rows_for(formula, case, attempts.get(case["id"], []))]
        print_report(formula, cases, rows, "live" if args.live else "replay")
        for mismatch in mismatches:
            print(f"mismatch: {mismatch}")
        return 1 if mismatches else 0
    except DD.Usage as error:
        print(f"jev-probe: {error}", file=sys.stderr)
        return DD.USAGE_EXIT
    except DD.Invalid as error:
        print(f"jev-probe: {error}", file=sys.stderr)
        return DD.INVALID_EXIT


if __name__ == "__main__":
    sys.exit(main())
