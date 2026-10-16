#!/usr/bin/env python3
"""Offline checks for jev routing (arch v2 M3c): shadow and route modes in task-dispatch.evaluate, the route gate,
the JevError fallback, the keyword-safety clear, next_ready left out without a successor, calibrate's numbers and
the task-spend judgement rows. jev is a fake ask function, so nothing leaves the machine. Writes only in a temp folder.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from io import StringIO
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "env/.config/tmux/scripts"
BUDGET = {"prompt_k": 150, "turns": 100}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dispatch = load("task_dispatch", "task-dispatch.py")
task_jev = dispatch.task_jev
task_state = dispatch.task_state
task_spend = load("task_spend", "task-spend.py")
FAVORABLE = task_jev.FAVORABLE


def check(label, condition, detail=None):
    if not condition:
        raise AssertionError(f"{label}: {detail}")


def fake_ask(overrides=None, error=None, conf=0.9, seen=None):
    """Stands in for task_jev.ask: answers every question the request asked, favourably unless overridden."""
    def ask(body, *, url, shape, env, key_path, asked=None, **_):
        if seen is not None:
            seen.append(body)
        if error:
            raise task_jev.JevError(error)
        answers = {qid: {"choice": FAVORABLE[qid], "confidence": conf} for qid in body["questions"]}
        for qid, choice in (overrides or {}).items():
            if qid in answers:
                answers[qid]["choice"] = choice
        return {"answers": answers, "latency_ms": 5, "input_tokens": 1000}

    return ask


def env_for(mode, threshold=None):
    env = {"TASK_JEV_MODE": mode}
    if threshold is not None:
        env["TASK_JEV_THRESHOLD"] = str(threshold)
    return env


def node(node_id, spec, after=()):
    return dispatch.task_plan.Node(id=node_id, agent="worker-dotfiles", spec=spec, after=list(after), scope=["env/x"],
                                   contracts=[], checkpoint=False, review="none", session="", budget=BUDGET,
                                   plan_hash="h")


def make_worktree(tmp):
    """A git worktree whose origin/HEAD names origin/main, with one change on top: the head sha the report names."""
    wt = tmp / "wt"
    wt.mkdir()

    def git(*args):
        return subprocess.run(["git", "-C", str(wt), "-c", "user.name=t", "-c", "user.email=t@example.org", *args],
                              check=True, capture_output=True, text=True).stdout.strip()
    git("init", "-q", "-b", "main")
    git("commit", "-q", "--allow-empty", "-m", "base")
    git("update-ref", "refs/remotes/origin/main", "HEAD")
    git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    (wt / "env/x").mkdir(parents=True)
    (wt / "env/x/f.py").write_text("x = 1\n", encoding="utf-8")
    git("add", "-A")
    git("commit", "-q", "-m", "change")
    return git("rev-parse", "HEAD")


def make_root(tmp, summary="Built the thing.", successor=True):
    root = tmp / "task"
    (root / "specs").mkdir(parents=True, exist_ok=True)
    (root / "specs/a.md").write_text("Goal: a\nDone when:\n- x works\n", encoding="utf-8")
    (root / "specs/b.md").write_text("Goal: b\n", encoding="utf-8")
    (root / "AGENTS.md").write_text(f"- worker-dotfiles: agent `worker-dotfiles`, worktree `{tmp / 'wt'}`\n", encoding="utf-8")
    report = root / "reports/worker-dotfiles/a.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({
        "step": "a", "agent": "worker-dotfiles", "head_sha": make_worktree(tmp), "files_changed": ["env/x/f.py"],
        "checks": [{"cmd": "t", "exit": 0}], "risks": [], "summary": summary, "needs_decision": None,
        "context_estimate_k": 40, "questions": [],
    }), encoding="utf-8")
    plan = {"a": node("a", "specs/a.md")}
    if successor:
        plan["b"] = node("b", "specs/b.md", after=["a"])
    return root, plan


def run(root, plan, env, **fake):
    """evaluate for step a with jev faked. Returns the exit code, whether route ran, the judgement and the requests."""
    seen = []
    base = {"PATH": os.environ.get("PATH", ""), "HOME": str(Path.home())}
    with mock.patch.dict(os.environ, {**base, **env}, clear=True), \
            mock.patch.object(dispatch, "route", return_value=(0, "decided")) as route, \
            mock.patch.object(task_jev, "ask", side_effect=fake_ask(seen=seen, **fake)):
        code, _, judged = dispatch.evaluate(root, "worker-dotfiles", "a", ["env/x"], BUDGET, plan)
    return {"code": code, "judged": judged, "routed": route.call_count, "bodies": seen}


def test_settings():
    check("route without a threshold", raises(lambda: dispatch.jev_settings({"TASK_JEV_MODE": "route"}), ValueError))
    check("route with a threshold", dispatch.jev_settings({"TASK_JEV_MODE": "route", "TASK_JEV_THRESHOLD": "0.8"}) == ("route", 0.8))
    check("default is shadow", dispatch.jev_settings({})[0] == "shadow")


def raises(call, error):
    try:
        call()
    except error:
        return True
    return False


def test_shadow_never_changes_routing(tmp):
    root, plan = make_root(tmp)
    off = run(root, plan, env_for("off"))
    shadow = run(root, plan, env_for("shadow"))
    check("shadow routes as off", shadow["code"] == off["code"] == 0 and shadow["routed"] == 1)
    check("shadow judgement recorded", shadow["judged"]["derived_route"] == "continue" and shadow["judged"]["mode"] == "shadow")
    unfavourable = run(root, plan, env_for("shadow"), overrides={"done_met": "no"})
    check("shadow still routes on an escalate", unfavourable["code"] == 0 and unfavourable["routed"] == 1)
    check("shadow derives escalate", unfavourable["judged"]["derived_route"] == "escalate")


def test_route_gate(tmp):
    root, plan = make_root(tmp)
    ok = run(root, plan, env_for("route", 0.8))
    check("route continues when all favourable and confident", ok["code"] == 0 and ok["routed"] == 1)
    low = run(root, plan, env_for("route", 0.8), conf=0.5)
    check("low confidence escalates without routing", low["code"] == dispatch.JEV_ESCALATE and low["routed"] == 0)
    check("the wake carries the answers", dispatch.jev_pointer(low["judged"])["answers"]["done_met"]["confidence"] == 0.5)
    bad = run(root, plan, env_for("route", 0.8), overrides={"risk_material": "yes"})
    check("an unfavourable answer escalates", bad["code"] == dispatch.JEV_ESCALATE and bad["routed"] == 0)


def test_jev_error_falls_back(tmp):
    root, plan = make_root(tmp)
    shadow = run(root, plan, env_for("shadow"), error="HTTP 500")
    judged = shadow["judged"]
    check("shadow still routes after a JevError", shadow["code"] == 0 and shadow["routed"] == 1)
    check("the error is recorded", judged["answers"] is None and judged["error"] == "JevError: HTTP 500")
    check("a failed judgement escalates", judged["derived_route"] == "escalate")
    route = run(root, plan, env_for("route", 0.8), error="HTTP 500")
    check("route escalates after a JevError", route["code"] == dispatch.JEV_ESCALATE and route["routed"] == 0)


def test_keyword_clears_only_on_all_favourable(tmp):
    root, plan = make_root(tmp, summary="Cleared out a delete step.", successor=False)
    shadow = run(root, plan, env_for("shadow"))
    check("keyword stops in shadow", shadow["code"] == dispatch.KEYWORD and shadow["routed"] == 0)
    cleared = run(root, plan, env_for("route", 0.8))
    check("keyword clears in route mode on all favourable", cleared["code"] == 0 and cleared["routed"] == 1)
    still = run(root, plan, env_for("route", 0.8), overrides={"done_met": "no"})
    check("keyword stays on one unfavourable answer", still["code"] == dispatch.KEYWORD and still["routed"] == 0)


def test_next_ready_only_with_a_successor(tmp):
    root, plan = make_root(tmp, successor=True)
    with_next = run(root, plan, env_for("shadow"))
    check("next_ready asked with a successor", "next_ready" in with_next["bodies"][0]["questions"])
    root, plan = make_root(tmp / "alone", successor=False)
    alone = run(root, plan, env_for("shadow"))
    check("next_ready left out without a successor", set(alone["bodies"][0]["questions"]) == set(task_jev.QUESTIONS) - {"next_ready"})
    check("no next_ready answer without a successor", "next_ready" not in alone["judged"]["answers"])
    check("four favourable answers continue", task_jev.derive_route(alone["judged"]["answers"], 0.8) == "continue")
    four = {qid: {"choice": FAVORABLE[qid], "confidence": 0.9} for qid in alone["judged"]["answers"]}
    check("parse accepts four answers when asked four", task_jev.parse_answers({"answers": four}, "native",
          [q for q in task_jev.QUESTIONS if q != "next_ready"])["done_met"]["choice"] == "yes")
    check("parse rejects four answers when asked five", raises(lambda: task_jev.parse_answers({"answers": four}, "native"),
          task_jev.JevError))


def test_calibrate(tmp):
    def build(folder, rows):
        root = folder / "cal"
        root.mkdir(parents=True)  # folder is made with it
        conn = task_state.connect(root)
        for number, (answers, derived, outcome) in enumerate(rows, start=1):
            task_state.record_judgement(conn, "a", number, {
                "model": "m", "request_hash": None, "answers": answers, "derived_route": derived, "mode": "shadow",
                "latency_ms": 1, "cost_usd": 0.0, "input_tokens": 1, "error": None})
            conn.execute("UPDATE judgements SET outcome = ? WHERE attempt = ?", (outcome, number))
        conn.close()
        return root

    def calibrate(root):
        out = StringIO()
        task_jev.calibrate(root, True, out)
        return json.loads(out.getvalue())

    favourable = {qid: {"choice": FAVORABLE[qid], "confidence": 0.9} for qid in FAVORABLE}
    check("too few steps", calibrate(build(tmp / "few", [(favourable, "continue", "continue")] * 3))["threshold"]
          == "insufficient data (3)")
    without_next = {qid: answer for qid, answer in favourable.items() if qid != "next_ready"}
    rows = [(without_next, "continue", "continue")] + [(favourable, "continue", "continue")] * 19
    rows.append((favourable, "continue", "resolved:retry"))  # final and not accepted; a bare stop is not final
    rows.append((favourable, "continue", "stopped:checks"))  # not final: excluded from the 21
    result = calibrate(build(tmp / "many", rows))
    check("calibrate counts 21 steps", result["judged"] == 21 and result["accepted"] == 20, result)
    check("one false continue", result["false_continue"] == 1, result)
    # Every threshold that routes the false continue away also routes every favourable step away: no usable threshold.
    check("no threshold with a continue", result["threshold"] == "none: no threshold with a false-continue-free continue over 21 steps"
          and result["would_continue"] is None, result["threshold"])
    # The false continue at 0.4 clears by the 0.5 floor, so 0.50 is clean and continues the favourable steps.
    unsure = rows[:-2] + [({qid: {"choice": FAVORABLE[qid], "confidence": 0.4} for qid in FAVORABLE}, "continue", "resolved:retry")]
    result = calibrate(build(tmp / "unsure", unsure + rows[-1:]))
    check("0.50 clean with continues", result["threshold"].startswith("0.50 ") and result["would_continue"] >= 19, result)
    check("next_ready ignored where absent", sum(cell["n"] for cell in result["buckets"]["next_ready"].values()) == 20)


def test_spend_judgements(tmp):
    tasks = tmp / "tasks"
    root = tasks / "demo"
    root.mkdir(parents=True)
    conn = task_state.connect(root)
    task_state.record_judgement(conn, "a", 1, {
        "model": "typesafe/jev-1.14", "request_hash": None, "answers": None, "derived_route": "escalate", "mode": "shadow",
        "latency_ms": 1, "cost_usd": None, "input_tokens": 1000000, "error": None})
    conn.close()
    rows = task_spend.judgement_responses(str(tasks))
    check("one judgement row", len(rows) == 1 and rows[0]["provider"] == "jev" and rows[0]["role"] == "judge", rows)
    cost_by_kind, tier = task_spend.price_turn(rows[0], task_spend.PRICES)
    check("judgement priced as jev input", abs(cost_by_kind["input"] - 0.042) < 1e-9 and tier == 0, cost_by_kind)


def main():
    test_settings()
    with tempfile.TemporaryDirectory(prefix="jev-route-fixture-") as folder:
        tmp = Path(folder)
        test_shadow_never_changes_routing(tmp / "shadow")
        test_route_gate(tmp / "gate")
        test_jev_error_falls_back(tmp / "error")
        test_keyword_clears_only_on_all_favourable(tmp / "keyword")
        test_next_ready_only_with_a_successor(tmp / "next")
        test_calibrate(tmp)
        test_spend_judgements(tmp)
    print("task-jev-route fixture: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
