#!/usr/bin/env python3
"""Run a Jev probe set through task-decide and score the answers.

    jev-probe.py --cases <cases.jsonl> [--formula <worker-step.toml>] [--live] [--runs 3]

The default is a dry run: it builds every request and checks each code route
against the case, with no network and no key. --live sends each non-code case
--runs times through task-decide's decide() and reports agreement per question
(strict 0.5 threshold, and band-aware), ambiguous cases apart, unstable cases,
latency and cost. Nothing is written. Stdlib only.
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


def check_code_route(formula, case):
    """Returns a mismatch message, or None when the code route matches the case."""
    route = DD.code_route(formula, case["report"])
    if case["expected"] is None:
        if ("escalate" if route else None) != case["expected_route_in_code"]:
            return f"{case['id']}: code route {'escalate' if route else 'none'}, case expects {case['expected_route_in_code']}"
    elif route:
        return f"{case['id']}: code routed ({route}) but the case expects Jev answers"
    return None


def dry_run(formula, cases):
    mismatches, requests, bytes_total = [], 0, 0
    for case in cases:
        mismatch = check_code_route(formula, case)
        if mismatch:
            mismatches.append(mismatch)
        elif case["expected"] is not None:
            body = DD.build_request(formula, case["report"], formula["decision"]["model"])
            requests += 1
            bytes_total += len(json.dumps(body))
    routed = sum(1 for case in cases if case["expected"] is None)
    print(f"dry run: {len(cases)} cases, {requests} requests built ({bytes_total} bytes), {routed} routed in code; no network, no key")
    for mismatch in mismatches:
        print(f"mismatch: {mismatch}")
    return 1 if mismatches else 0


def live_calls(formula, cases, runs):
    calls, mismatches = [], []
    for case in cases:
        mismatch = check_code_route(formula, case)
        if mismatch:
            mismatches.append(mismatch)
            continue
        if case["expected"] is None:
            continue
        for run in range(runs):
            start = time.perf_counter()
            record, _ = DD.decide(formula, case["report"], model=formula["decision"]["model"], key_loader=DD.load_key, url=DD.endpoint())
            calls.append((case, run, record, time.perf_counter() - start))
    return calls, mismatches


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(pct / 100 * len(ordered)) - 1)]


def score_noul(q, calls):
    low, high = q.get("band", (0.5, 0.5))
    rows = {g: {"n": 0, "strict": 0, "answered": 0, "agree": 0, "wrong": []} for g in GROUPS}
    sides = {}
    for case, run, record, _ in calls:
        answer = record["answers"].get(q["key"])
        if not isinstance(answer, dict) or "noul" not in answer:
            continue
        p, label = answer["noul"], case["expected"][q["key"]]
        strict_pred = p >= 0.5
        band_pred = None if low < p < high else p >= high
        sides.setdefault((case["id"], q["key"]), set()).add(strict_pred)
        for group in ("all", "ambiguous" if case["ambiguous"] else "clear"):
            row = rows[group]
            row["n"] += 1
            row["strict"] += strict_pred == label
            if band_pred is not None:
                row["answered"] += 1
                row["agree"] += band_pred == label
                if band_pred != label:
                    row["wrong"].append(f"{case['id']}#{run} p={p:.2f}")
    return rows, sides


def score_choice(q, calls):
    rows = {g: {"n": 0, "strict": 0, "answered": 0, "agree": 0, "wrong": []} for g in GROUPS}
    sides = {}
    n_options = len(q["criteria"])
    for case, run, record, _ in calls:
        answer = record["answers"].get(q["key"])
        if not isinstance(answer, dict) or "probabilities" not in answer:
            continue
        probs = {option: answer["probabilities"][option] for option in q["criteria"]}
        best = max(probs, key=probs.get)
        confidence = (probs[best] - 1 / n_options) / (1 - 1 / n_options)
        label = case["expected"][q["key"]]
        sides.setdefault((case["id"], q["key"]), set()).add(best)
        for group in ("all", "ambiguous" if case["ambiguous"] else "clear"):
            row = rows[group]
            row["n"] += 1
            row["strict"] += best == label
            if confidence >= q["min_confidence"]:
                row["answered"] += 1
                row["agree"] += best == label
                if best != label:
                    row["wrong"].append(f"{case['id']}#{run} {best} (conf {confidence:.2f})")
    return rows, sides


def print_question(q, rows, sides):
    print(f"{q['key']} ({q['type']})")
    for group in GROUPS:
        row = rows[group]
        if not row["n"]:
            continue
        n = row["n"]
        line = f"  {group:<9} n={n} strict {row['strict']}/{n} ({row['strict'] / n:.0%})"
        line += f" | band: answered {row['answered']}/{n} ({row['answered'] / n:.0%}), agree {row['agree']}/{row['answered']}, confidently wrong {len(row['wrong'])}"
        print(line)
        for wrong in row["wrong"]:
            print(f"    wrong: {wrong}")
    unstable = sorted(case_id for (case_id, key), seen in sides.items() if key == q["key"] and len(seen) > 1)
    print(f"  unstable: {', '.join(unstable) if unstable else 'none'}")


def print_summary(formula, cases, calls, mismatches):
    print(f"live: {len(calls)} calls over {len({c[0]['id'] for c in calls})} cases; {sum(1 for c in cases if c['expected'] is None)} routed in code (not called)")
    for mismatch in mismatches:
        print(f"mismatch: {mismatch}")
    models = Counter(record["model"] for _, _, record, _ in calls)
    print("models seen: " + (", ".join(f"{m} ({n})" for m, n in models.items()) or "none"))
    for q in DD.questions_of(formula):
        if q["type"] == "noul":
            rows, sides = score_noul(q, calls)
        else:
            rows, sides = score_choice(q, calls)
        print_question(q, rows, sides)
    seconds = [dt for _, _, _, dt in calls]
    p50, p95 = percentile(seconds, 50), percentile(seconds, 95)
    if p50 is not None:
        print(f"latency: p50 {p50 * 1000:.0f} ms, p95 {p95 * 1000:.0f} ms")
    costs = [r["usage"]["cost"] for _, _, r, _ in calls if isinstance(r.get("usage"), dict) and _is_cost(r["usage"].get("cost"))]
    print(f"cost: ${sum(costs):.6f} ({len(costs)} calls with usage.cost, {len(calls) - len(costs)} without)")
    routes = Counter(record["route"] for _, _, record, _ in calls)
    service = sum(1 for _, _, r, _ in calls if r["reason"].startswith("decision service unavailable"))
    print("routes: " + ", ".join(f"{k} {v}" for k, v in sorted(routes.items())) + f"; service errors {service}")


def _is_cost(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Run a Jev probe set through task-decide and score it.")
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--formula", type=Path, default=DEFAULT_FORMULA)
    parser.add_argument("--live", action="store_true", help="send the real requests (needs the key)")
    parser.add_argument("--runs", type=int, default=3, help="calls per case with --live")
    args = parser.parse_args(argv)
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    try:
        formula = DD.load_formula(args.formula)
        cases = load_cases(args.cases, formula)
        if not args.live:
            return dry_run(formula, cases)
        calls, mismatches = live_calls(formula, cases, args.runs)
        print_summary(formula, cases, calls, mismatches)
        return 1 if mismatches else 0
    except DD.Usage as error:
        print(f"jev-probe: {error}", file=sys.stderr)
        return DD.USAGE_EXIT
    except DD.Invalid as error:
        print(f"jev-probe: {error}", file=sys.stderr)
        return DD.INVALID_EXIT


if __name__ == "__main__":
    sys.exit(main())
