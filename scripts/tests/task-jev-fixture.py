#!/usr/bin/env python3
"""Offline checks for task_jev.py (arch v2 M3a-2, M3d-1): redaction of planted secrets, the request bytes, the
field caps, the live gate, the URL and redirect rules, the answer parsing, the 429 retry and the CLI's dry run.

The network is a fake post function. The redirect check uses a loopback server that nothing else reaches, and the
CLI runs only its dry run and its gate refusal. Writes only inside a temporary folder.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "env/.config/tmux/scripts"
CLI = SCRIPTS / "task-dispatch.py"
_spec = importlib.util.spec_from_file_location("task_jev", SCRIPTS / "task_jev.py")
jev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jev)

# Every planted secret carries PLANTED, so one substring check covers the whole corpus.
PLANTED = [
    "OPENROUTER_API_KEY=sk-or-v1-PLANTEDKEY0123456789abcdef",
    "Authorization: Bearer PLANTEDBEARER987654321",
    "-----BEGIN RSA PRIVATE KEY-----\nPLANTEDPEM\n-----END RSA PRIVATE KEY-----",
    '"api_key": "PLANTEDJSON"',
    "token ghp_PLANTEDGITHUB0123456789",
    "mail person@example.com",
    'DB_PASSWORD="PLANTEDdb one" and TOKEN=\'PLANTEDxyz\'',
    'API_KEY="PLANTED a b c" secret = "PLANTED a b"',
    "password: PLANTEDhunter2 --password PLANTEDflag --token PLANTEDtok --password=PLANTEDeq",
    "Authorization: Basic PLANTEDbasic==",
    "https://user:PLANTEDurlpw@example.org/x and https://PLANTEDuser@example.org/y",
    '{"token": 987654321, "api_key": "PLANTEDquoted \\" escaped"}',
    "-----BEGIN OPENSSH PRIVATE KEY-----\nPLANTEDOPEN",
]
PATHS = ["/home/otheruser/tasks/x", "/root/ops/y"]
CHOICES = {"done_met": "yes", "risk_material": "no", "contract_change": "no", "next_ready": "yes",
           "privileged_action": "no"}
KEY_VALUE = "sk-or-v1-KEYVALUE0123456789abcdef"
URL = "https://openrouter.ai/api/alpha/decisions"


def planted_report():
    return {
        "step": "m3a-2", "agent": "worker-dotfiles", "branch": "investigate-spending", "head_sha": "abc1234",
        "files_changed": ["env/.config/tmux/scripts/task_jev.py"], "checks": [{"command": "make test", "exit_code": 0}],
        "risks": ["none", PLANTED[-1]], "needs_decision": None, "context_estimate_k": 40,
        "credentials": {"db_passwd": "PLANTEDtree", "retries": 3}, "auth_token": 987654321,
        "summary": "Done. " + " ".join(PATHS + PLANTED[:-1]) + f" wrote {Path.home()}/tasks/x",
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
    text = jev.redact("\n".join(PATHS + PLANTED[:-1]) + f"\nand {Path.home()}/tasks")  # one line per secret
    for leaked in ("PLANTED", "person@example.com", "987654321", "otheruser", "/root/", str(Path.home())):
        assert leaked not in text, (leaked, text)
    assert "~/tasks" in text and "[email]" in text and "[private key]" in text and "[token]" in text
    assert "[private key]" in jev.redact(PLANTED[-1]) and "PLANTED" not in jev.redact(PLANTED[-1])


def test_redaction_outputs():
    cases = {
        'DB_PASSWORD="PLANTEDdb one"': "DB_PASSWORD=[redacted]",
        'secret = "PLANTED a b"': "secret = [redacted]",
        "password: PLANTEDhunter2": "password: [redacted]",
        "--token PLANTEDtok": "--token [redacted]",
        "--password=PLANTEDeq": "--password=[redacted]",
        "https://user:PLANTEDurlpw@example.org/x": "https://[redacted]@example.org/x",
        "Authorization: Basic PLANTEDbasic==": "Authorization: [redacted]",
        "/home/otheruser/tasks/x": "~/tasks/x",
        "/root/ops/y": "~/ops/y",
        "/rootfs/x": "/rootfs/x",
        '{"api_key": "PLANTEDquoted \\" escaped", "n": 1}': '{"api_key": "[redacted]", "n": 1}',
        "tokens: 500": "tokens: [redacted]",
        "password: hunter two": "password: [redacted]",  # an unquoted value runs to the end of its line
        'password: "a b" more': 'password: [redacted] more',  # a quoted value ends at its quote
        "note password: PLANTEDline hunter two\nnext line": "note password: [redacted]\nnext line",
        "eyJhbGciOiJIUzI1NiJ9.PLANTEDpayload.sig_1-x": "[token]",  # a JWT
        "eyJhbGciOiJIUzI1NiJ9.PLANTEDpayload.": "[token]",  # an unsigned one
        "Set-Cookie: sid=PLANTEDck; Path=/": "Set-Cookie: [redacted]",
        "Cookie: a=PLANTEDc; b=2": "Cookie: [redacted]",
        "--cookie PLANTEDflag": "--cookie [redacted]",
        '{"Cookie": "PLANTEDjson"}': '{"Cookie": "[redacted]"}',
    }
    for raw, expected in cases.items():
        assert jev.redact(raw) == expected, (raw, jev.redact(raw))


def test_tree_redaction():
    tree = jev.redact_tree({"api_key": 123456789, "nested": {"auth_token": "PLANTEDtree", "retries": 3, "none": None},
                            "checks": [{"password": "PLANTEDlist"}], "text": "OPENROUTER_API_KEY=PLANTEDenv"})
    assert tree == {"api_key": "[redacted]", "nested": {"auth_token": "[redacted]", "retries": 3, "none": None},
                    "checks": [{"password": "[redacted]"}], "text": "OPENROUTER_API_KEY=[redacted]"}, tree


def test_clip_comes_after_redaction():
    cap = jev.CAPS["report_field"]
    token = "sk-or-v1-PLANTEDCLIP0123456789ab"
    # Cut after "sk-or-v1-PLANTED": clipping first would leave an unmatched fragment that still shows the marker.
    state = jev.build_state({"step": "s", "summary": "x" * (cap - 17) + " " + token}, "", [], "", "")
    assert state["worker_report"]["summary"] == "x" * (cap - 17) + " [token]", state["worker_report"]["summary"]


def test_request_bytes_hold_no_secret():
    for shape in ("native", "chat"):
        state = jev.build_state(planted_report(), "Goal\n" + PLANTED[1], ["env/x"],
                                "C6: " + PLANTED[2] + "\n" + "y" * 40000, "diff " + PATHS[0] + " " + PLANTED[7],
                                next_spec=PLANTED[8])
        body = jev.build_body(state, jev.MODEL, shape, jev.asked_questions("next_step" in state))
        request = jev.make_request(URL, KEY_VALUE, body)
        data = request.data.decode("utf-8")
        for leaked in ("PLANTED", "person@example.com", "987654321", "otheruser", "/home/", "/root/", KEY_VALUE):
            assert leaked not in data, (shape, leaked)
        parsed = json.loads(data)
        if shape == "chat":
            json.loads(parsed["messages"][0]["content"])
        assert request.get_header("Authorization") == f"Bearer {KEY_VALUE}"
        assert len(data) < 60000, len(data)


def test_url_rules(tmp):
    calls = []

    def post(url, key, body):
        calls.append(url)
        return valid_native()

    for url in ("https://openrouter.ai/api/alpha/decisions", "https://api.openrouter.ai/x"):
        jev.check_url(url)
    bad = ["http://openrouter.ai/x", "https://evil.example/x", "https://openrouter.ai.evil.example/x",
           "https://evilopenrouter.ai/x", "https://openrouter.ai:8443/x", "https://user:pw@openrouter.ai/x",
           "https://openrouter.ai@evil.example/x", "u"]
    env = {"TASK_ROLE": "orchestrator", "TASK_JEV_LIVE": "1"}
    for url in bad:
        try:
            jev.ask({}, url=url, shape="native", env=env, key_path=key_file(tmp), post=post)
        except jev.Usage as error:
            assert "pw" not in str(error), str(error)  # the refusal never echoes the URL, which may carry a password
            continue
        raise AssertionError(f"accepted {url}")
    assert calls == [], "a refused URL still reached the network"


def test_redirects_are_not_followed():
    hits = []

    class Redirector(BaseHTTPRequestHandler):
        def do_POST(self):
            hits.append(self.path)
            self.send_response(307)
            self.send_header("Location", "/second")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, format, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Redirector)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        try:
            jev._post(f"http://127.0.0.1:{server.server_port}/first", KEY_VALUE, {})
        except urllib.error.HTTPError as error:
            assert error.code == 307, error.code
        else:
            raise AssertionError("a redirect was followed")
        assert hits == ["/first"], hits
    finally:
        server.shutdown()
        server.server_close()


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
            jev.ask({}, url=URL, shape="native", env=env, key_path=path, post=post)
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
    result = jev.ask({}, url=URL, shape="native", env={"TASK_ROLE": "orchestrator", "TASK_JEV_LIVE": "1"},
                     key_path=key, post=post, sleep=slept.append)
    assert slept == [2] and seen == [KEY_VALUE, KEY_VALUE], (slept, seen)
    assert result["answers"]["done_met"] == {"choice": "yes", "confidence": 0.9}, result
    assert result["input_tokens"] == 1234 and isinstance(result["latency_ms"], int)

    def server_error(url, key_value, body):
        raise urllib.error.HTTPError("u", 500, "down", {}, None)

    try:
        jev.ask({}, url=URL, shape="native", env={"TASK_ROLE": "orchestrator", "TASK_JEV_LIVE": "1"},
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


def test_bad_keys_are_refused_unseen(tmp):
    """M3f item 2: a key with a space, newline or non-ASCII character is refused, and the refusal does not show it."""
    key_path = key_file(tmp)
    for bad in ("sk-or-v1-PLANTEDKEY\nECHOLINE", "sk-or-v1 PLANTEDSPACE", "sk-or-v1-PLANTEDé", "sk-or-v1-PLANTED\x01"):
        try:
            jev.load_key({"OPENROUTER_API_KEY": bad}, key_path)
        except jev.Usage as error:
            assert "PLANTED" not in str(error) and "ECHOLINE" not in str(error), str(error)
        else:
            raise AssertionError(f"accepted {bad!r}")
    assert jev.load_key({"OPENROUTER_API_KEY": KEY_VALUE}, key_path) == KEY_VALUE


def test_library_errors_keep_no_text():
    """M3f item 2: a ValueError from http.client can echo the header, so send keeps only its type name."""
    def echo(url, key_value, body):
        raise ValueError(f"Invalid header value b'Bearer {key_value}\\n'")

    try:
        jev.send(echo, URL, KEY_VALUE, {}, lambda seconds: None)
    except jev.JevError as error:
        assert str(error) == "ValueError" and KEY_VALUE not in str(error), str(error)
    else:
        raise AssertionError("a ValueError must raise JevError")


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
        test_redaction_outputs()
        test_tree_redaction()
        test_clip_comes_after_redaction()
        test_request_bytes_hold_no_secret()
        test_dry_run_is_redacted_for_both_shapes(tmp)
        test_gate_refuses_before_the_key(tmp)
        test_url_rules(tmp)
        test_redirects_are_not_followed()
        test_answers_and_retry(tmp)
        test_parse_rejects_bad_replies()
        test_bad_keys_are_refused_unseen(tmp)
        test_library_errors_keep_no_text()
        test_cli_gate_refuses_without_network(tmp)
    print("task-jev fixture: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
