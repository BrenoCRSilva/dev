#!/usr/bin/env python3
"""Offline checks for task_jev.py (arch v2 M3a-2): redaction of planted secrets, the request shapes, the
field caps, the live gate, the answer parsing, the 429 retry and the CLI's dry run and gate refusal.

The network is a fake post function. The CLI runs only its dry run and its gate refusal, so nothing leaves
the machine. Writes only inside a temporary folder.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "env/.config/tmux/scripts"
CLI = SCRIPTS / "task-dispatch.py"
_spec = importlib.util.spec_from_file_location("task_jev", SCRIPTS / "task_jev.py")
jev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jev)

PLANTED = [
    "OPENROUTER_API_KEY=sk-or-v1-PLANTEDKEY0123456789abcdef",
    "Authorization: Bearer PLANTEDBEARER987654321",
    "-----BEGIN RSA PRIVATE KEY-----\nPLANTEDPEM\n-----END RSA PRIVATE KEY-----",
    '"api_key": "PLANTEDJSON"',
    "token ghp_PLANTEDGITHUB0123456789",
    "mail person@example.com",
]
CHOICES = {"done_met": "yes", "risk_material": "no", "contract_change": "no", "next_ready": "yes",
           "privileged_action": "no"}
KEY_VALUE = "sk-or-v1-KEYVALUE0123456789abcdef"


def planted_report():
    return {
        "step": "m3a-2", "agent": "worker-dotfiles", "branch": "investigate-spending", "head_sha": "abc1234",
        "files_changed": ["env/.config/tmux/scripts/task_jev.py"], "checks": [{"command": "make test", "exit_code": 0}],
        "risks": ["none"], "needs_decision": None, "context_estimate_k": 40,
        "summary": "Done. " + " ".join(PLANTED) + f" wrote {Path.home()}/tasks/x",
    }


def valid_native():
    return {"answers": {qid: {"type": "choice", "choice": choice, "confidence": 0.9} for qid, choice in CHOICES.items()},
            "usage": {"prompt_tokens": 1234}}


def key_file(folder, mode=0o600):
    path = folder / "openrouter.env"
    path.write_text(f"OPENROUTER_API_KEY={KEY_VALUE}\n", encoding="utf-8")
    path.chmod(mode)
    return path


def run_cli(args, env):
    return subprocess.run([sys.executable, "-I", str(CLI), "jev", *args], capture_output=True, text=True,
                          env=env, timeout=60)


def test_redaction():
    text = jev.redact(" ".join(PLANTED) + f" and {Path.home()}/tasks")
    for leaked in ("PLANTED", "person@example.com", str(Path.home())):
        assert leaked not in text, (leaked, text)
    assert "~/tasks" in text and "[email]" in text and "[private key]" in text


def test_dry_run_is_redacted_for_both_shapes(tmp):
    spec = tmp / "spec.md"
    spec.write_text("Goal: jev client.\nDone when:\n- smoke passes\n" + PLANTED[1] + "\n", encoding="utf-8")
    report = tmp / "report.json"
    report.write_text(json.dumps(planted_report()), encoding="utf-8")
    contracts = tmp / "contracts.md"
    contracts.write_text("C6: " + PLANTED[2] + "\n" + "x" * 40000, encoding="utf-8")
    env = {k: v for k, v in os.environ.items() if k not in ("TASK_ROLE", "TASK_JEV_LIVE", "TASK_JEV_SHAPE")}
    base = ["smoke", "--dry-run", "--report", str(report), "--spec", str(spec), "--contracts", str(contracts),
            "--next-spec", str(spec), "--scope", "env/.config/tmux/scripts", "--worktree", str(tmp)]
    for shape in ("native", "chat"):
        done = run_cli(base, {**env, "TASK_JEV_SHAPE": shape})
        assert done.returncode == 0, done.stderr
        for leaked in ("PLANTED", "person@example.com", "BEGIN RSA", str(Path.home())):
            assert leaked not in done.stdout, (shape, leaked)
        assert len(done.stdout) < 48000, len(done.stdout)
        body = json.loads(done.stdout)
        if shape == "chat":
            assert set(body) == {"model", "messages", "provider"}, body.keys()
            body = json.loads(body["messages"][0]["content"])
        else:
            assert set(body) == {"model", "state", "questions", "provider"}, body.keys()
        assert set(body["questions"]) == set(jev.QUESTIONS), body["questions"].keys()
        assert all(q["type"] == "choice" for q in body["questions"].values())
        assert set(body["questions"]["done_met"]["criteria"]) == {"yes", "no", "unclear"}
        if shape == "native":
            assert body["state"]["contract_excerpt"].endswith("[truncated]")
            assert body["state"]["step"]["scope"] == ["env/.config/tmux/scripts"]


def test_gate_refuses_before_the_key(tmp):
    calls = []

    def post(url, key, body):
        calls.append(url)
        return valid_native()

    ok_env = {"TASK_ROLE": "orchestrator", "TASK_JEV_LIVE": "1"}
    key = key_file(tmp)
    loose_dir = tmp / "loose"
    loose_dir.mkdir()
    cases = [
        ({"TASK_JEV_LIVE": "1"}, key),
        ({"TASK_ROLE": "worker-dotfiles", "TASK_JEV_LIVE": "1"}, key),
        ({"TASK_ROLE": "orchestrator"}, key),
        (ok_env, tmp / "missing.env"),
        (ok_env, key_file(loose_dir, 0o644)),
    ]
    for env, path in cases:
        try:
            jev.ask({}, url="u", shape="native", env=env, key_path=path, post=post)
        except jev.Usage:
            continue
        raise AssertionError(f"gate let {env} through")
    assert calls == [], "a refused request still reached the network"


def test_answers_and_retry(tmp):
    key = key_file(tmp)
    seen = []
    replies = [urllib.error.HTTPError("u", 429, "busy", {}, None), valid_native()]

    def post(url, key_value, body):
        seen.append(key_value)
        reply = replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply

    slept = []
    result = jev.ask({}, url="u", shape="native", env={"TASK_ROLE": "orchestrator", "TASK_JEV_LIVE": "1"},
                     key_path=key, post=post, sleep=slept.append)
    assert slept == [2] and seen == [KEY_VALUE, KEY_VALUE], (slept, seen)
    assert result["answers"]["done_met"] == {"choice": "yes", "confidence": 0.9}, result
    assert result["input_tokens"] == 1234 and isinstance(result["latency_ms"], int)

    def server_error(url, key_value, body):
        raise urllib.error.HTTPError("u", 500, "down", {}, None)

    try:
        jev.ask({}, url="u", shape="native", env={"TASK_ROLE": "orchestrator", "TASK_JEV_LIVE": "1"},
                key_path=key, post=server_error, sleep=slept.append)
    except jev.JevError as error:
        assert str(error) == "HTTP 500" and KEY_VALUE not in str(error)
    else:
        raise AssertionError("a 500 must raise JevError")


def test_parse_rejects_bad_replies():
    bad = [
        {"answers": {**valid_native()["answers"], "done_met": {"choice": ["yes"], "confidence": 0.9}}},
        {"answers": {**valid_native()["answers"], "done_met": {"choice": "maybe", "confidence": 0.9}}},
        {"answers": {k: v for k, v in valid_native()["answers"].items() if k != "privileged_action"}},
        {"answers": {**valid_native()["answers"], "next_ready": {"choice": "yes", "confidence": 1.5}}},
        {"answers": {**valid_native()["answers"], "next_ready": {"choice": "yes", "confidence": True}}},
        "not an object",
    ]
    for reply in bad:
        try:
            jev.parse_answers(reply, "native")
        except jev.JevError:
            continue
        raise AssertionError(f"accepted {reply!r}")
    chat = {"choices": [{"message": {"content": json.dumps(valid_native())}}]}
    assert jev.parse_answers(chat, "chat")["next_ready"]["choice"] == "yes"
    try:
        jev.parse_answers({"choices": [{"message": {"content": "```json"}}]}, "chat")
    except jev.JevError:
        pass
    else:
        raise AssertionError("a non-JSON chat reply must raise JevError")


def test_cli_gate_refuses_without_network(tmp):
    report = tmp / "cli-report.json"
    report.write_text(json.dumps(planted_report()), encoding="utf-8")
    env = {k: v for k, v in os.environ.items() if k not in ("TASK_ROLE", "TASK_JEV_LIVE")}
    done = run_cli(["smoke", "--report", str(report), "--worktree", str(tmp)], env)
    assert done.returncode == 2 and "TASK_ROLE" in done.stderr, (done.returncode, done.stderr)
    missing = run_cli(["smoke", "--dry-run", "--report", str(tmp / "nope.json")], env)
    assert missing.returncode == 3, missing.returncode


def main():
    with tempfile.TemporaryDirectory(prefix="jev-fixture-") as folder:
        tmp = Path(folder)
        test_redaction()
        test_dry_run_is_redacted_for_both_shapes(tmp)
        test_gate_refuses_before_the_key(tmp)
        test_answers_and_retry(tmp)
        test_parse_rejects_bad_replies()
        test_cli_gate_refuses_without_network(tmp)
    print("task-jev fixture: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
