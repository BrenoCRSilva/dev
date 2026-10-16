"""Jev client for the step router (arch v2 §5, T1): builds the gating request for one worker report,
redacts it, and reads the five answers. Stdlib only.

    task-dispatch.py jev smoke [--dry-run] --report <report.json> [--spec <spec.md>] [--scope <path>]...
                               [--next-spec <spec.md>] [--contracts <file>] [--worktree <dir>] [--base <ref>]

--dry-run prints the redacted request and makes no request; it reads no key. A live call needs
TASK_ROLE=orchestrator, TASK_JEV_LIVE=1 and ~/.config/task-agents/openrouter.env at mode 600, all checked
before the key file is opened. The key comes from OPENROUTER_API_KEY, else the file's line; it is never
printed or put in an error. Env: TASK_JEV_MODEL (typesafe/jev-1.14), TASK_JEV_SHAPE (native | chat),
TASK_JEV_URL, TASK_JEV_KEYFILE.

Exit: 0 answers printed (or dry run); 2 usage (flags, gate, key); 3 unreadable or invalid input; 20 jev
unavailable or its reply unusable (the caller escalates).
"""
import argparse
import http.client
import json
import os
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

MODEL = "typesafe/jev-1.14"
SHAPES = ("native", "chat")
ENDPOINTS = {
    "native": "https://openrouter.ai/api/alpha/decisions",
    "chat": "https://openrouter.ai/api/v1/chat/completions",
}
PROVIDER = {"zdr": True, "data_collection": "deny", "allow_fallbacks": False}
CAPS = {"spec": 16000, "contract": 16000, "diffstat": 4000, "next_spec": 4000}  # ~12k tokens in all
RETRY_STATUS = {429, 529}
TIMEOUT_S = 30
USAGE_EXIT, INVALID_EXIT, SERVICE_EXIT = 2, 3, 20

# Every question is a choice; the criteria are the options the reply may pick.
QUESTIONS = {
    "done_met": (
        "Is every done-when item in `step.spec` shown as met by `worker_report.checks` and `diffstat`?",
        {"yes": "each done-when item has matching evidence", "no": "at least one item lacks evidence",
         "unclear": "the evidence does not decide it"},
    ),
    "risk_material": (
        "Does `diffstat` touch a path outside `step.scope`, or change deploy or config files?",
        {"no": "no such path changed", "yes": "an out-of-scope path or a deploy or config file changed"},
    ),
    "contract_change": (
        "Does `worker_report` say it changed a behaviour or field described in `contract_excerpt`?",
        {"no": "no contract behaviour or field changed", "yes": "a contract behaviour or field changed"},
    ),
    "next_ready": (
        "Does `worker_report` satisfy every prerequisite that `next_step.spec` requires?",
        {"yes": "all prerequisites are met", "no": "at least one prerequisite is unmet"},
    ),
    "privileged_action": (
        "Does the step perform or require a privileged action: package/system install, sudo, deploy to the "
        "home directory, push, or writes outside the repo?",
        {"no": "no privileged action", "yes": "a privileged action is performed or required"},
    ),
}

# shortcut: regex redaction covers the common key shapes and KEY=VALUE, not every secret format; add a pattern
# when a new kind of secret shows up in a report.
REDACTIONS = (
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[private key]"),
    (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer [token]"),
    (re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_\w{20,}"
                r"|\bAKIA[0-9A-Z]{16}\b|\bxox[abprs]-[A-Za-z0-9-]{10,}|\bAIza[\w-]{35}"), "[token]"),
    (re.compile(r'(?i)"([^"\\]*(?:key|token|secret|passw(?:or)?d)[^"\\]*)"\s*:\s*"[^"\\]*"'), r'"\1": "[redacted]"'),
    (re.compile(r"(?i)\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]*)\s*=\s*[^\s\"',;]+"),
     r"\1=[redacted]"),
    (re.compile(r"[\w.%+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}"), "[email]"),
    (re.compile(re.escape(str(Path.home())) + r"(?![\w.-])"), "~"),
)


class Usage(Exception):
    """Bad flags, the live gate or an unsafe key file: exit 2."""


class InputError(Exception):
    """The report, spec or contract cannot be read or is invalid: exit 3."""


class JevError(Exception):
    """jev could not answer: exit 20."""


def redact(text):
    for pattern, replacement in REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


def redact_tree(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, dict):
        return {key: redact_tree(item) for key, item in value.items()}
    if isinstance(value, list):
        return [redact_tree(item) for item in value]
    return value


def redacted_json(body, indent=None):
    return redact(json.dumps(body, ensure_ascii=False, indent=indent))


def clip(text, cap):
    return text if len(text) <= cap else text[:cap] + "\n[truncated]"


def read_text(path, what):
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise InputError(f"cannot read {what} {path}: {error}")


def diffstat(worktree, base, head):
    try:
        done = subprocess.run(["git", "-C", str(worktree), "diff", "--stat", f"{base}...{head}"],
                              capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unavailable: {type(error).__name__}"
    return done.stdout if done.returncode == 0 else f"unavailable: git exit {done.returncode}"


def load_state(args):
    """The state the questions read, redacted. Every text field is capped so the request stays near 12k tokens."""
    try:
        report = json.loads(read_text(args.report, "report"))
    except ValueError as error:
        raise InputError(f"report is not JSON: {error}")
    if not isinstance(report, dict):
        raise InputError("report must be a JSON object")
    spec = read_text(args.spec, "spec") if args.spec else ""
    contract = read_text(args.contracts, "contracts") if args.contracts else ""
    state = {
        "step": {"id": report.get("step"), "spec": clip(spec, CAPS["spec"]), "scope": args.scope},
        "worker_report": report,
        "diffstat": clip(diffstat(args.worktree, args.base, report.get("head_sha") or "HEAD"), CAPS["diffstat"]),
        "contract_excerpt": clip(contract, CAPS["contract"]),
    }
    if args.next_spec:
        state["next_step"] = {"spec": clip(read_text(args.next_spec, "next spec"), CAPS["next_spec"])}
    return redact_tree(state)


def build_body(state, model, shape):
    body = {
        "model": model,
        "state": state,
        "questions": {qid: {"type": "choice", "instructions": text, "criteria": criteria}
                      for qid, (text, criteria) in QUESTIONS.items()},
    }
    if shape == "chat":
        body = {"model": model, "messages": [{"role": "user", "content": json.dumps(body, ensure_ascii=False)}]}
    body["provider"] = PROVIDER
    return body


def live_gate(env, key_path):
    """Refuses a live request before the key file is opened, unless every condition holds."""
    if env.get("TASK_ROLE") != "orchestrator":
        raise Usage("live requests are for the orchestrator only: TASK_ROLE must be orchestrator")
    if env.get("TASK_JEV_LIVE") != "1":
        raise Usage("no live opt-in: set TASK_JEV_LIVE=1")
    try:
        mode = stat.S_IMODE(key_path.stat().st_mode)
    except OSError:
        raise Usage(f"no key file at {key_path}; a live request needs it at mode 600")
    if mode != 0o600:
        raise Usage(f"{key_path} must be mode 600 (it is {mode:o}); run chmod 600 on it")


def load_key(env, key_path):
    """Called only after live_gate passes: the env key, else the key file's line."""
    key = env.get("OPENROUTER_API_KEY", "").strip()
    if key:
        return key
    try:
        lines = key_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        raise Usage(f"cannot read {key_path}")
    for line in lines:
        match = re.fullmatch(r"\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*(.*?)\s*", line)
        if match and match.group(1).strip("\"'"):
            return match.group(1).strip("\"'")
    raise Usage(f"{key_path} has no OPENROUTER_API_KEY line")


def _post(url, key, body):
    request = urllib.request.Request(
        url,
        data=redacted_json(body).encode("utf-8"),
        method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_S) as reply:
        raw = reply.read()
    try:
        return json.loads(raw)
    except ValueError:
        raise JevError("reply is not JSON")


def parse_answers(response, shape):
    """{qid: {choice, confidence}} for every question, or JevError."""
    if shape == "chat":
        # shortcut: a fenced JSON reply is not unwrapped, so it escalates; add the unwrap when chat is used.
        try:
            response = json.loads(response["choices"][0]["message"]["content"])
        except (KeyError, IndexError, TypeError, ValueError):
            raise JevError("chat reply has no JSON answers")
    answers = response.get("answers", response) if isinstance(response, dict) else None
    if not isinstance(answers, dict):
        raise JevError("reply has no answers object")
    parsed = {}
    for qid, (_, criteria) in QUESTIONS.items():
        answer = answers.get(qid)
        if not isinstance(answer, dict) or not isinstance(answer.get("choice"), str) or answer["choice"] not in criteria:
            raise JevError(f"{qid}: no valid choice")
        confidence = answer.get("confidence")
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
            raise JevError(f"{qid}: no valid confidence")
        parsed[qid] = {"choice": answer["choice"], "confidence": float(confidence)}
    return parsed


def send(post, url, key, body, sleep):
    """One retry on 429 or 529, after 2 s. Any other failure raises JevError without the key."""
    try:
        return post(url, key, body)
    except urllib.error.HTTPError as error:
        if error.code not in RETRY_STATUS:
            raise JevError(f"HTTP {error.code}")
    except (OSError, http.client.HTTPException) as error:
        raise JevError(type(error).__name__)
    sleep(2)
    try:
        return post(url, key, body)
    except urllib.error.HTTPError as error:
        raise JevError(f"HTTP {error.code}")
    except (OSError, http.client.HTTPException) as error:
        raise JevError(type(error).__name__)


def ask(body, *, url, shape, env, key_path, post=_post, sleep=time.sleep):
    """One request after the live gate. Returns {answers, latency_ms, input_tokens}; raises Usage or JevError."""
    live_gate(env, key_path)
    key = load_key(env, key_path)
    started = time.monotonic()
    response = send(post, url, key, body, sleep)
    answers = parse_answers(response, shape)
    usage = response.get("usage") if isinstance(response, dict) else None
    tokens = usage.get("prompt_tokens", usage.get("input_tokens")) if isinstance(usage, dict) else None
    return {"answers": answers, "latency_ms": round((time.monotonic() - started) * 1000), "input_tokens": tokens}


def main(argv):
    parser = argparse.ArgumentParser(prog="task-dispatch.py jev",
                                     description="Send one worker report to Jev, or print the request (--dry-run).")
    parser.add_argument("action", choices=["smoke"])
    parser.add_argument("--dry-run", action="store_true", help="print the redacted request; no request, no key")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--spec", type=Path)
    parser.add_argument("--scope", action="append", default=[])
    parser.add_argument("--next-spec", type=Path)
    parser.add_argument("--contracts", type=Path)
    parser.add_argument("--worktree", type=Path, default=Path.cwd())
    parser.add_argument("--base", default="main")
    args = parser.parse_args(argv)
    env = os.environ
    shape = env.get("TASK_JEV_SHAPE", "native")
    try:
        if shape not in SHAPES:
            raise Usage(f"TASK_JEV_SHAPE must be native or chat, not {shape}")
        body = build_body(load_state(args), env.get("TASK_JEV_MODEL", MODEL), shape)
        if args.dry_run:
            print(redacted_json(body, indent=2))
            return 0
        key_path = Path(env.get("TASK_JEV_KEYFILE", Path.home() / ".config/task-agents/openrouter.env"))
        result = ask(body, url=env.get("TASK_JEV_URL", ENDPOINTS[shape]), shape=shape, env=env, key_path=key_path)
    except Usage as error:
        print(f"task-dispatch jev: {error}", file=sys.stderr)
        return USAGE_EXIT
    except InputError as error:
        print(f"task-dispatch jev: {error}", file=sys.stderr)
        return INVALID_EXIT
    except JevError as error:
        print(f"task-dispatch jev: jev unavailable: {error}", file=sys.stderr)
        return SERVICE_EXIT
    for qid, answer in result["answers"].items():
        print(f"{qid}: {answer['choice']} confidence={answer['confidence']:.2f}")
    print(f"latency_ms={result['latency_ms']} input_tokens={result['input_tokens']}")
    return 0
