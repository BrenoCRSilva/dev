#!/usr/bin/env python3
"""Offline checks for task-spend.py on synthetic transcripts in a temporary folder.

Expected values are worked out by hand from the PRICES table. Covers streamed-message
dedup, role attribution from cwd, a subagent sidechain, the Haiku prompt-size tier, an
unpriced model, a Codex rollout, a bad line, --since/--until, --by task, --split, the
--json and --prices options and their refusals. The --efficiency checks cover tool-call
counting, the 5m/1h cache-write split with an unsplit write, prompt-size ratios and p95,
the task view and the unpriced Codex turn. The --state checks cover spend per node, attempt and tier against a state.db
built by task_state, the window and attribution rules, --since and --until, and the refusals. Writes only
inside a temporary folder.
Run: python3 -I scripts/tests/task-spend-fixture.py
"""
import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "env", ".config", "tmux", "scripts", "task-spend.py")
sys.path.insert(0, os.path.join(ROOT, "env", ".config", "tmux", "scripts"))

import task_state  # noqa: E402


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


def close(a, b, tol=1e-9):
    return abs(a - b) < tol


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
        {"type": "turn_context", "payload": {"turn_id": "t-1", "model": "gpt-7-test",
                                             "cwd": os.path.join(t1, "dotfiles")}},
        {"type": "token_usage_record", "timestamp": "2026-10-15T14:00:00Z",
         "payload": {"turn_id": "t-1", "response_id": "r1",
                     "usage": {"input_tokens": 300, "cached_input_tokens": 100, "output_tokens": 20}}},
    ])
    return {"--claude-dir": claude, "--codex-dir": codex, "--tasks-dir": tasks}


def usage(input_tokens, output_tokens, cache_read=0, split=None, cache_write=0):
    """A message usage block; split=(5m, 1h) adds the cache_creation breakdown."""
    block = {"input_tokens": input_tokens, "output_tokens": output_tokens,
             "cache_read_input_tokens": cache_read, "cache_creation_input_tokens": cache_write}
    if split is not None:
        block["cache_creation"] = {"ephemeral_5m_input_tokens": split[0], "ephemeral_1h_input_tokens": split[1]}
    return block


def message(msg_id, model, stamp, cwd, session, block, content=()):
    return {"type": "assistant", "timestamp": stamp, "cwd": cwd, "sessionId": session,
            "message": {"id": msg_id, "model": model, "usage": block, "content": list(content)}}


def tool_use(tool_id):
    return {"type": "tool_use", "id": tool_id}


def build_efficiency(base):
    """Synthetic logs for --efficiency; returns the flags the CLI is pointed at."""
    tasks = os.path.join(base, "home", "tasks")
    t2 = os.path.join(tasks, "t2")
    dotfiles = os.path.join(t2, "dotfiles")
    claude = os.path.join(base, "claude")
    codex = os.path.join(base, "codex")
    write_lines(os.path.join(claude, "e", "o1.jsonl"), [
        # a1 is streamed as three records: a text block, then two tool calls. Output keeps the largest count.
        message("a1", "claude-opus-5-5", "2026-10-16T10:00:00Z", t2, "o1", usage(100, 10, 1000, (500, 200), 700),
                [{"type": "text"}]),
        message("a1", "claude-opus-5-5", "2026-10-16T10:00:01Z", t2, "o1", usage(100, 20, 1000, (500, 200), 700),
                [tool_use("u1")]),
        message("a1", "claude-opus-5-5", "2026-10-16T10:00:02Z", t2, "o1", usage(100, 50, 1000, (500, 200), 700),
                [tool_use("u2")]),
        message("a2", "claude-opus-5-5", "2026-10-16T10:05:00Z", t2, "o1", usage(200, 20, 3000, (0, 0))),
        # a3 has no cache_creation split, so its 4000 cache-write tokens count as 5m.
        message("a3", "claude-opus-5-5", "2026-10-16T10:10:00Z", t2, "o1", usage(50, 30, 0, None, 4000),
                [tool_use("u3")]),
    ])
    write_lines(os.path.join(claude, "e", "w1.jsonl"), [
        message("b1", "claude-haiku-5-5", "2026-10-16T10:01:00Z", dotfiles, "w1", usage(10, 5, 90), [tool_use("v1")]),
    ])
    # Twenty turns with prompts of 1000 to 20000 tokens: the nearest-rank p95 is the 19th, 19000.
    write_lines(os.path.join(claude, "e", "w2.jsonl"), [
        message(f"w{k}", "claude-haiku-5-5", f"2026-10-16T11:{k:02d}:00Z", dotfiles, "w2", usage(1000 * k, 1))
        for k in range(1, 21)
    ])
    write_lines(os.path.join(claude, "e", "r1.jsonl"), [
        message("c1", "claude-sonnet-5-5", "2026-10-16T12:00:00Z", os.path.join(t2, "research"), "r1",
                usage(1000, 100, 10_000, (2000, 0), 2000)),
    ])
    write_lines(os.path.join(codex, "rollout.jsonl"), [
        {"type": "session_meta", "payload": {"session_id": "cx2", "cwd": dotfiles}},
        {"type": "turn_context", "payload": {"turn_id": "t-1", "model": "gpt-6-luna", "cwd": dotfiles}},
        # The tool item sits just before the record of the response that made it.
        {"type": "response_item", "payload": {"type": "function_call", "name": "exec", "call_id": "c1"}},
        {"type": "token_usage_record", "timestamp": "2026-10-16T10:30:00Z",
         "payload": {"turn_id": "t-1", "response_id": "r9",
                     "usage": {"input_tokens": 300, "cached_input_tokens": 100, "output_tokens": 20,
                               "reasoning_output_tokens": 5}}},
    ])
    return ["--claude-dir", claude, "--codex-dir", codex, "--tasks-dir", tasks]


def stamp(clock):
    return f"2026-10-16T{clock}Z"


def epoch(clock):
    return datetime.datetime.fromisoformat(f"2026-10-16T{clock}+00:00").timestamp()


def build_state(base):
    """Task t3 with a state.db and transcripts; returns the state.db path and the CLI's directory flags.
    Two worker attempts (a1 10:05-10:20, a2 10:30 and still running), a researcher attempt (b1 10:12-10:14)."""
    tasks = os.path.join(base, "home", "tasks")
    root = os.path.join(tasks, "t3")
    dotfiles = os.path.join(root, "dotfiles")
    research = os.path.join(root, "research")
    claude = os.path.join(base, "claude")
    os.makedirs(root)
    conn = task_state.connect(root)
    conn.execute("INSERT INTO nodes (id, agent, status) VALUES ('n-a', 'worker-dotfiles', 'running')")
    conn.execute("INSERT INTO nodes (id, agent, status) VALUES ('n-b', 'researcher', 'done')")
    attempts = "INSERT INTO attempts (node, attempt, started_at, ended_at) VALUES (?, ?, ?, ?)"
    conn.execute(attempts, ("n-a", 1, epoch("10:05:00"), epoch("10:20:00")))
    conn.execute(attempts, ("n-a", 2, epoch("10:30:00"), None))
    conn.execute(attempts, ("n-b", 1, epoch("10:12:00"), epoch("10:14:00")))
    conn.execute("INSERT INTO events (ts, node, kind) VALUES (?, NULL, 'reconcile')", (epoch("10:00:00"),))
    judged = "INSERT INTO judgements (node, attempt, model, cost_usd, judged_at) VALUES (?, ?, ?, ?, ?)"
    conn.execute(judged, ("n-a", 1, "typesafe/jev-1.14", 0.01, epoch("10:15:00")))
    conn.execute(judged, ("n-a", 2, "typesafe/jev-1.14", 0.02, epoch("10:40:00")))
    conn.execute(judged, ("n-b", 1, "typesafe/jev-1.14", 0.005, epoch("10:13:30")))
    conn.close()
    # Every response is 1000 input and 100 output tokens: $0.003 at Sonnet's list price.
    write_lines(os.path.join(claude, "s", "main.jsonl"), [
        assistant("o0", "claude-sonnet-5-5", stamp("09:59:00"), root, "s-orch", 1000, 100),
        assistant("o1", "claude-sonnet-5-5", stamp("10:30:00"), root, "s-orch", 1000, 100),
        assistant("w1", "claude-sonnet-5-5", stamp("10:10:00"), dotfiles, "s-w", 1000, 100),
        assistant("w2", "claude-sonnet-5-5", stamp("10:25:00"), dotfiles, "s-w", 1000, 100),
        assistant("w3", "claude-sonnet-5-5", stamp("10:31:00"), dotfiles, "s-w", 1000, 100),
        assistant("x1", "claude-sonnet-5-5", stamp("10:10:30"), os.path.join(tasks, "t4", "dotfiles"), "s-x",
                  1000, 100),
    ])
    write_lines(os.path.join(claude, "s", "subagents", "agent-a.jsonl"), [
        assistant("sa1", "claude-sonnet-5-5", stamp("10:12:00"), dotfiles, "s-w", 1000, 100, sidechain=True),
    ])
    write_lines(os.path.join(claude, "r", "r.jsonl"), [
        assistant("r1", "claude-sonnet-5-5", stamp("10:13:00"), research, "s-r", 1000, 100),
    ])
    flags = ["--claude-dir", claude, "--codex-dir", os.path.join(base, "none"), "--tasks-dir", tasks]
    return os.path.join(root, "state.db"), flags


def check_state(env):
    with tempfile.TemporaryDirectory() as base:
        state, flags = build_state(base)

        def digest():
            with open(state, "rb") as handle:
                return hashlib.sha256(handle.read()).hexdigest()

        before = digest()

        def rows(*args, key):
            return {key(row): row for row in json.loads(run(["--json", "--state", state, *args, *flags], env).stdout)}

        def want(row, turns, usd, jev=0.0):
            check(row["turns"] == turns and close(row["usd"], usd, 1e-9) and close(row["jev_usd"], jev, 1e-9),
                  f"{row['node']} {row['attempt']} {row['tier']}: {row}")

        # By node: n-a has a1 (worker and subagent turns) and a2; the orchestrator at 10:30 is T2; the 09:59
        # orchestrator turn and the 10:25 worker turn fall outside every window.
        by_node = rows("--by", "node", key=lambda row: (row["node"], row["tier"]))
        check(sorted(by_node) == [("-", "T2"), ("-", "unattributed"), ("n-a", "work"), ("n-b", "work")],
              f"node rows: {sorted(by_node)}")
        want(by_node[("n-a", "work")], 3, 0.009, 0.03)
        want(by_node[("n-b", "work")], 1, 0.003, 0.005)
        want(by_node[("-", "T2")], 1, 0.003)
        want(by_node[("-", "unattributed")], 2, 0.006)
        check(by_node[("n-b", "work")]["agent"] == "researcher" and by_node[("-", "T2")]["agent"] == "orchestrator",
              f"agents: {by_node}")

        # By attempt: the same figures split per attempt; the default --by is node.
        by_attempt = rows("--by", "attempt", key=lambda row: (row["node"], row["attempt"], row["tier"]))
        want(by_attempt[("n-a", 1, "work")], 2, 0.006, 0.01)
        want(by_attempt[("n-a", 2, "work")], 1, 0.003, 0.02)
        want(by_attempt[("n-b", 1, "work")], 1, 0.003, 0.005)
        check(run(["--json", "--state", state, *flags], env).stdout == run(
            ["--json", "--state", state, "--by", "node", *flags], env).stdout, "default --by is node")

        # By tier: work is the attempts, T1 the judge (3 judgements), T2 the orchestrator.
        by_tier = rows("--by", "tier", key=lambda row: row["tier"])
        check(sorted(by_tier) == ["T1", "T2", "unattributed", "work"], f"tier rows: {sorted(by_tier)}")
        want(by_tier["work"], 4, 0.012)
        want(by_tier["T1"], 3, 0.035)
        want(by_tier["T2"], 1, 0.003)
        want(by_tier["unattributed"], 2, 0.006)
        check(by_tier["T1"]["agent"] == "jev", f"judge row: {by_tier['T1']}")

        # --since is inclusive and --until exclusive: 10:12 to 10:31 holds the subagent, the researcher, the
        # orchestrator and the 10:25 worker turn; the judgements count by judged_at.
        window = ["--since", "2026-10-16T10:12:00Z", "--until", "2026-10-16T10:31:00Z"]
        ranged = rows(*window, "--by", "node", key=lambda row: (row["node"], row["tier"]))
        want(ranged[("n-a", "work")], 1, 0.003, 0.01)
        want(ranged[("n-b", "work")], 1, 0.003, 0.005)
        want(ranged[("-", "T2")], 1, 0.003)
        want(ranged[("-", "unattributed")], 1, 0.003)

        # The text table prints, and the database is read-only.
        text = run(["--state", state, "--by", "tier", *flags], env).stdout
        check("T2" in text and "unattributed" in text, f"text table: {text}")
        check(digest() == before, "state.db changed")

        # Refusals: --by node without --state, --state with another --by, a split, a missing file, a non-database.
        run(["--by", "node", *flags], env, expect=2)
        run(["--state", state, "--by", "day", *flags], env, expect=2)
        run(["--state", state, "--split", "2026-10-16", *flags], env, expect=2)
        run(["--state", os.path.join(base, "missing.db"), *flags], env, expect=2)
        bad = os.path.join(base, "bad.db")
        write_lines(bad, ["not a database"])
        run(["--state", bad, *flags], env, expect=2)


def check_efficiency(env):
    with tempfile.TemporaryDirectory() as base:
        dirs = build_efficiency(base)

        def efficiency(*args):
            return json.loads(run(["--efficiency", "--json", *args, *dirs], env).stdout)

        # Session o1: 3 turns, 3 tool calls, tokens and USD per kind. Opus 5.5: a1 0.0057, a2 0.0018, a3 0.0208.
        sessions = {row["session"]: row for row in efficiency("--group", "session")}
        o1 = sessions["o1"]
        check(o1["turns"] == 3 and o1["sessions"] == 1 and o1["tasks"] == 1, f"o1 counts: {o1}")
        check(close(o1["tool_calls_per_turn"], 1.0), f"o1 tool calls per turn: {o1['tool_calls_per_turn']}")
        check((o1["input_tokens"], o1["output_tokens"], o1["cache_read_tokens"], o1["cache_write_5m_tokens"],
               o1["cache_write_1h_tokens"]) == (350, 100, 4000, 4500, 200), f"o1 tokens: {o1}")
        check(close(o1["cost_usd"], 0.0283) and close(o1["usd_cache_write_5m"], 0.0225)
              and close(o1["usd_cache_write_1h"], 0.0016), f"o1 USD by kind: {o1}")
        check(close(o1["usd_per_turn"], 0.0283 / 3), f"o1 USD per turn: {o1['usd_per_turn']}")
        check(close(o1["prompt_avg"], 9050 / 3) and o1["prompt_p95"] == 4050, f"o1 prompt size: {o1}")
        check(close(o1["cache_hit"], 4000 / 9050) and close(o1["write_share"], 4700 / 9050), f"o1 ratios: {o1}")
        check(o1["unsplit_write_turns"] == 1 and o1["unpriced_turns"] == 0, f"o1 unsplit/unpriced: {o1}")

        # Session w2: 20 turns; prompt average 10,500 and p95 19,000; Haiku cost 0.02101 (all input, bar 20 output).
        w2 = sessions["w2"]
        check(w2["turns"] == 20 and w2["prompt_p95"] == 19000 and close(w2["prompt_avg"], 10_500),
              f"w2 prompt size: {w2}")
        check(close(w2["cost_usd"], 0.02101) and w2["cache_hit"] == 0, f"w2 cost: {w2}")

        # Task view: orchestrator share of USD over the priced turns (o1 + b1 + w2 + c1; the Codex turn is unpriced),
        # and worker turns per orchestrator turn (21 Claude worker turns + 1 Codex worker turn over 3).
        tasks = efficiency("--group", "task")
        check(len(tasks) == 1 and tasks[0]["task"] == "t2", f"task rows: {tasks}")
        total = 0.0283 + 4.4e-6 + 0.02101 + 0.01 + 31e-6
        check(close(tasks[0]["orchestrator_usd_share"], 0.0283 / total, 1e-9), f"orchestrator share: {tasks[0]}")
        check(close(tasks[0]["worker_turns_per_orchestrator_turn"], 22 / 3, 1e-9), f"worker turns: {tasks[0]}")

        roles = {row["role"]: row for row in efficiency("--group", "role")}
        check(set(roles) == {"orchestrator", "worker-dotfiles", "researcher"}, f"role rows: {sorted(roles)}")
        worker = roles["worker-dotfiles"]
        check(worker["turns"] == 22 and worker["sessions"] == 3 and worker["unpriced_turns"] == 0,
              f"worker-dotfiles row: {worker}")
        check(len(efficiency()) == 3, "default group is role")
        check(len(efficiency("--group", "role,task")) == 3, "role,task rows")

        # Codex turn: input 300 less 100 cached is 200 uncached; output 20 already holds the 5 reasoning tokens.
        # Priced at luna's rates: 200 x 0.1 + 100 x 0.01 + 20 x 0.5 = 31 micro-USD. One function_call.
        models = {row["model"]: row for row in efficiency("--group", "model")}
        luna = models["gpt-6-luna"]
        check((luna["input_tokens"], luna["cache_read_tokens"], luna["output_tokens"]) == (200, 100, 20),
              f"gpt-6-luna tokens: {luna}")
        check(close(luna["cost_usd"], 31e-6) and luna["unpriced_turns"] == 0
              and close(luna["tool_calls_per_turn"], 1.0), f"gpt-6-luna row: {luna}")
        check(models["claude-haiku-5-5"]["turns"] == 21, f"haiku turns: {models['claude-haiku-5-5']}")

        # --since is applied before grouping: from 10:03 the orchestrator has a2 and a3 only.
        since = json.loads(run(["--efficiency", "--json", "--group", "role", "--since", "2026-10-16T10:03:00+00:00",
                                *dirs], env).stdout)
        check({row["role"]: row["turns"] for row in since}["orchestrator"] == 2, f"since: {since}")

        # Text: the task view, the unsplit footnote, and --split printing a before and an after table.
        text = run(["--efficiency", "--group", "task", *dirs], env).stdout
        check("orchestrator share of USD" in text and "cache writes with no 5m/1h split: 1 response(s)" in text,
              f"text output: {text}")
        check("USD (Codex: list-price equivalent (plan-billed))" in text and "Codex USD is a list-price equivalent"
              in text, f"Codex labels: {text}")
        split = run(["--efficiency", "--split", "2026-10-16T10:03:00+00:00", *dirs], env).stdout.splitlines()
        heads = [line.split()[0] for line in split if line.startswith(("before ", "after "))]
        check(heads == ["before", "after"], f"split headers: {heads}")

        run(["--efficiency", "--by", "task", *dirs], env, expect=2)
        run(["--group", "role", *dirs], env, expect=2)
        run(["--efficiency", "--split", "2026-10-16", "--json", *dirs], env, expect=2)


def check_codex_fallback(env):
    """A rollout with no token_usage_record uses its token_count events. last_token_usage is the per-call
    delta, a repeated total is skipped, and each response takes the tool items since the previous event."""
    with tempfile.TemporaryDirectory() as base:
        dotfiles = os.path.join(base, "home", "tasks", "t4", "dotfiles")
        codex = os.path.join(base, "codex")

        def count(stamp, total, last):
            return {"type": "event_msg", "timestamp": stamp,
                    "payload": {"type": "token_count", "info": {"total_token_usage": total, "last_token_usage": last}}}

        first = {"input_tokens": 500, "cached_input_tokens": 200, "cache_write_input_tokens": 0,
                 "output_tokens": 30, "reasoning_output_tokens": 10}
        write_lines(os.path.join(codex, "rollout.jsonl"), [
            {"type": "session_meta", "payload": {"session_id": "cx4", "cwd": dotfiles}},
            {"type": "turn_context", "payload": {"turn_id": "t-4", "model": "gpt-6-astra", "cwd": dotfiles}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "f", "call_id": "c1"}},
            count("2026-10-16T10:00:00Z", {"input_tokens": 500, "cached_input_tokens": 200, "output_tokens": 40}, first),
            # The same total again: a repeat of the event above, so it is skipped.
            count("2026-10-16T10:00:01Z", {"input_tokens": 500, "cached_input_tokens": 200, "output_tokens": 40}, first),
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec", "call_id": "c2"}},
            count("2026-10-16T10:01:00Z", {"input_tokens": 700, "cached_input_tokens": 600, "output_tokens": 45},
                  {"input_tokens": 200, "cached_input_tokens": 0, "output_tokens": 5}),
        ])
        rows = json.loads(run(["--efficiency", "--json", "--group", "model", "--codex-dir", codex,
                               "--claude-dir", os.path.join(base, "none"), "--tasks-dir",
                               os.path.join(base, "home", "tasks")], env).stdout)
        check(len(rows) == 1 and rows[0]["model"] == "gpt-6-astra", f"fallback rows: {rows}")
        row = rows[0]
        # Two responses, not three: the repeat is skipped. Cached input is subtracted; reasoning is not added again.
        check(row["turns"] == 2, f"repeat not skipped: {row}")
        check((row["input_tokens"], row["cache_read_tokens"], row["output_tokens"]) == (500, 200, 35),
              f"fallback tokens: {row}")
        check(row["tool_calls_per_turn"] == 1.0, f"fallback tool items: {row}")
        # 300 x 10 + 200 x 1.0 + 30 x 50 = 4,700 and 200 x 10 + 5 x 50 = 2,250 micro-USD.
        check(close(row["cost_usd"], 6950e-6), f"fallback cost: {row}")

    print("codex fallback: ok")


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
                dict(input_tokens=100, output_tokens=10, cost=(100 * 5.00 + 10 * 25.00) / 1e6, sessions=1, unpriced=0),
            ("2026-10-15", "t1", "worker-dotfiles", "gpt-7-test"):
                dict(input_tokens=200, output_tokens=20, cost=0.0, sessions=1, unpriced=1, cache_read=100),
            ("2026-10-16", "t1", "researcher", "claude-sonnet-5-5"):
                dict(input_tokens=1000, output_tokens=100, cost=(1000 * 2.00 + 100 * 10.00 + 10_000 * 0.20
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
        check("gpt-7-test" in stderr and "claude-opus-5" not in stderr, f"unpriced models not named: {stderr}")
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
        check(lines["researcher"][5:] == ["1", "1", "0.0100", "0.0100"], f"split researcher after: {lines}")
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

        check_efficiency(env)
    check_codex_fallback(env)
    check_state(env)

    print("task-spend fixture: ok")


if __name__ == "__main__":
    main()
