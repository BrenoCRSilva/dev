#!/usr/bin/env python3
"""Offline checks for task-spend.py on synthetic transcripts in a temporary folder.

Expected values are worked out by hand from the PRICES table. Covers streamed-message
dedup, role attribution from cwd, a subagent sidechain, the Haiku prompt-size tier, an
unpriced model, a Codex rollout, a bad line, --since/--until, --by task, --split, the
--json and --prices options and their refusals. Writes only inside a temporary folder.
Run: python3 -I scripts/tests/task-spend-fixture.py
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "env", ".config", "tmux", "scripts", "task-spend.py")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def check(condition, message):
    if not condition:
        fail(message)


def write_lines(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line if isinstance(line, str) else json.dumps(line))
            handle.write("\n")


def assistant(msg_id, model, stamp, cwd, session, input_tokens, output_tokens, cache_read=0, cache_write=0,
              sidechain=False):
    return {
        "type": "assistant", "timestamp": stamp, "cwd": cwd, "sessionId": session, "isSidechain": sidechain,
        "message": {
            "id": msg_id, "model": model,
            "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens,
                      "cache_read_input_tokens": cache_read, "cache_creation_input_tokens": cache_write},
        },
    }


def run(args, env, expect=0):
    result = subprocess.run([sys.executable, "-I", CLI, *args], capture_output=True, text=True, env=env)
    check(result.returncode == expect, f"{args}: exit {result.returncode}, want {expect}: {result.stderr}")
    return result


def close(a, b):
    return abs(a - b) < 1e-9


def build(base):
    """Synthetic logs under base; returns the paths the CLI is pointed at."""
    tasks = os.path.join(base, "home", "tasks")
    t1 = os.path.join(tasks, "t1")
    claude = os.path.join(base, "claude")
    codex = os.path.join(base, "codex")
    scratch = os.path.join(base, "home", "scratch")
    write_lines(os.path.join(claude, "p", "s1.jsonl"), [
        {"type": "user", "timestamp": "2026-10-15T09:59:00Z", "cwd": t1, "sessionId": "s-orch"},
        # m1 is streamed as two records with one message id; its output count is the larger one.
        assistant("m1", "claude-haiku-5-5", "2026-10-15T10:00:00Z", t1, "s-orch", 1000, 10),
        assistant("m1", "claude-haiku-5-5", "2026-10-15T10:00:01Z", t1, "s-orch", 1000, 100),
        "{not json",
        # Prompt 120,000 tokens is above the 100k tier, so Haiku's higher prices apply.
        assistant("m2", "claude-haiku-5-5", "2026-10-16T01:00:00Z", t1, "s-orch", 120_000, 1000),
    ])
    write_lines(os.path.join(claude, "p", "s1", "subagents", "agent-a1.jsonl"), [
        assistant("m9", "claude-haiku-5-5", "2026-10-15T10:30:00Z", t1, "s-orch", 500, 50, sidechain=True),
    ])
    write_lines(os.path.join(claude, "p", "s2.jsonl"), [
        assistant("m3", "claude-opus-5", "2026-10-15T12:00:00Z", os.path.join(t1, "dotfiles"), "s-work", 100, 10),
    ])
    write_lines(os.path.join(claude, "p", "s3.jsonl"), [
        # Cache write with no 5m/1h split falls back to the plain count (priced as 5m).
        assistant("m4", "claude-sonnet-5-5", "2026-10-16T09:00:00Z", os.path.join(t1, "research"), "s-res",
                  1000, 100, cache_read=10_000, cache_write=2000),
    ])
    write_lines(os.path.join(claude, "q", "s4.jsonl"), [
        assistant("m5", "claude-haiku-5-5", "2026-10-15T13:00:00Z", scratch, "s-other", 100, 10),
    ])
    write_lines(os.path.join(codex, "rollout.jsonl"), [
        {"type": "session_meta", "payload": {"session_id": "cx1", "cwd": os.path.join(t1, "dotfiles")}},
        {"type": "turn_context", "payload": {"turn_id": "t-1", "model": "gpt-6-luna",
                                             "cwd": os.path.join(t1, "dotfiles")}},
        {"type": "token_usage_record", "timestamp": "2026-10-15T14:00:00Z",
         "payload": {"turn_id": "t-1", "response_id": "r1",
                     "usage": {"input_tokens": 300, "cached_input_tokens": 100, "output_tokens": 20}}},
    ])
    return {"--claude-dir": claude, "--codex-dir": codex, "--tasks-dir": tasks}


def main():
    env = {**os.environ, "TZ": "UTC"}
    with tempfile.TemporaryDirectory() as base:
        dirs = [part for flag, path in build(base).items() for part in (flag, path)]

        # Default run: every row, one per day, role and model.
        rows = {
            (row["date"], row["task"], row["role"], row["model"]): row
            for row in json.loads(run(["--json", *dirs], env).stdout)
        }
        expected = {
            ("2026-10-15", "t1", "orchestrator", "claude-haiku-5-5"):
                dict(input_tokens=1000, output_tokens=100, cost=150 / 1e6, sessions=1, unpriced=0),
            ("2026-10-16", "t1", "orchestrator", "claude-haiku-5-5"):
                dict(input_tokens=120_000, output_tokens=1000, cost=(120_000 * 0.50 + 1000 * 2.50) / 1e6,
                     sessions=1, unpriced=0),
            ("2026-10-15", "t1", "subagent", "claude-haiku-5-5"):
                dict(input_tokens=500, output_tokens=50, cost=(500 * 0.10 + 50 * 0.50) / 1e6, sessions=1, unpriced=0),
            ("2026-10-15", "t1", "worker-dotfiles", "claude-opus-5"):
                dict(input_tokens=100, output_tokens=10, cost=0.0, sessions=1, unpriced=1),
            ("2026-10-15", "t1", "worker-dotfiles", "gpt-6-luna"):
                dict(input_tokens=200, output_tokens=20, cost=0.0, sessions=1, unpriced=1, cache_read=100),
            ("2026-10-16", "t1", "researcher", "claude-sonnet-5-5"):
                dict(input_tokens=1000, output_tokens=100, cost=(1000 * 2.00 + 100 * 10.00 + 10_000 * 0.10
                                                                 + 2000 * 2.50) / 1e6,
                     sessions=1, unpriced=0, cache_read=10_000, cache_write=2000),
            ("2026-10-15", "-", "other", "claude-haiku-5-5"):
                dict(input_tokens=100, output_tokens=10, cost=(100 * 0.10 + 10 * 0.50) / 1e6, sessions=1, unpriced=0),
        }
        check(set(rows) == set(expected), f"row keys {sorted(rows)}")
        for key, want in expected.items():
            row = rows[key]
            check(row["input_tokens"] == want["input_tokens"], f"{key} input {row['input_tokens']}")
            check(row["output_tokens"] == want["output_tokens"], f"{key} output {row['output_tokens']}")
            check(row["sessions"] == want["sessions"], f"{key} sessions {row['sessions']}")
            check(row["unpriced_turns"] == want["unpriced"], f"{key} unpriced {row['unpriced_turns']}")
            check(row["cache_read_tokens"] == want.get("cache_read", 0), f"{key} cache read")
            check(row["cache_write_tokens"] == want.get("cache_write", 0), f"{key} cache write")
            check(abs(row["cost_usd"] - round(want["cost"], 6)) < 1e-6, f"{key} cost {row['cost_usd']}")

        # Warnings go to stderr; the bad line and unpriced models are named there.
        stderr = run(["--json", *dirs], env).stderr
        check("claude-opus-5" in stderr and "gpt-6-luna" in stderr, f"unpriced models not named: {stderr}")
        check("skipped 1 bad lines" in stderr, f"bad line not counted: {stderr}")

        # --since is inclusive and --until exclusive: 10-16 holds the orchestrator and researcher.
        since = {(r["date"], r["role"]) for r in json.loads(
            run(["--json", "--since", "2026-10-16", *dirs], env).stdout)}
        check(since == {("2026-10-16", "orchestrator"), ("2026-10-16", "researcher")}, f"since: {since}")
        until = {r["date"] for r in json.loads(run(["--json", "--until", "2026-10-16", *dirs], env).stdout)}
        check(until == {"2026-10-15"}, f"until: {until}")

        # --by task sums over days: one orchestrator row for t1, with both days' input.
        by_task = [r for r in json.loads(run(["--json", "--by", "task", *dirs], env).stdout)
                   if r["role"] == "orchestrator"]
        check(len(by_task) == 1 and by_task[0]["date"] is None and by_task[0]["input_tokens"] == 121_000,
              f"by task: {by_task}")

        # --split: after 10-16 00:00 the orchestrator has one active day, one session, and $0.0625.
        split = run(["--split", "2026-10-16T00:00:00Z", *dirs], env).stdout.splitlines()
        lines = {line.split()[0]: line.split() for line in split[2:] if line.strip()}
        check(lines["orchestrator"][5:] == ["1", "1", "0.0625", "0.0625"], f"split orchestrator: {lines}")
        check(lines["researcher"][1:5] == ["0", "0", "-", "-"], f"split researcher before: {lines}")
        check(lines["researcher"][5:] == ["1", "1", "0.0090", "0.0090"], f"split researcher after: {lines}")
        run(["--split", "2026-10-16", "--json", *dirs], env, expect=2)

        # --prices overrides a model: opus-5 gets 1.00 input and 2.00 output per million.
        prices = os.path.join(base, "prices.json")
        write_lines(prices, [json.dumps({"claude-opus-5": [{"upto": None, "input": 1.0, "output": 2.0,
                                                           "cache_read": 0.1, "cache_write_5m": 1.25,
                                                           "cache_write_1h": 2.0}]})])
        override = {(r["role"], r["model"]): r for r in json.loads(
            run(["--json", "--prices", prices, *dirs], env).stdout)}
        opus = override[("worker-dotfiles", "claude-opus-5")]
        check(close(opus["cost_usd"], 0.00012) and opus["unpriced_turns"] == 0, f"override: {opus}")
        bad = os.path.join(base, "bad.json")
        write_lines(bad, [json.dumps({"claude-opus-5": [{"upto": None, "input": 1.0}]})])
        run(["--prices", bad, *dirs], env, expect=2)

        # An empty folder is an empty report, not an error.
        empty = os.path.join(base, "empty")
        os.makedirs(empty)
        check(json.loads(run(["--json", "--claude-dir", empty, "--codex-dir", empty, "--tasks-dir", empty],
                             env).stdout) == [], "empty folder")

    print("task-spend fixture: ok")


if __name__ == "__main__":
    main()
