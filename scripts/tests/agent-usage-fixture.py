#!/usr/bin/env python3
# Fixture for scripts/agent-usage.py: synthetic Claude and Codex logs with
# expected totals worked out by hand. Run: python3 -I scripts/tests/agent-usage-fixture.py
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join(ROOT, "scripts", "agent-usage.py")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def write_lines(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        for line in lines:
            handle.write(line if isinstance(line, str) else json.dumps(line))
            handle.write("\n")


def claude_turn(message_id, model, cwd, session, stamp, usage):
    return {
        "type": "assistant",
        "sessionId": session,
        "cwd": cwd,
        "timestamp": stamp,
        "message": {"id": message_id, "model": model, "usage": usage},
    }


def codex_meta(cwd, session):
    return {"type": "session_meta", "payload": {"cwd": cwd, "session_id": session}}


def codex_turn(turn_id, model, cwd):
    return {"type": "turn_context", "payload": {"turn_id": turn_id, "model": model, "cwd": cwd}}


def codex_usage(turn_id, response_id, stamp, usage):
    return {
        "type": "token_usage_record",
        "timestamp": stamp,
        "payload": {"turn_id": turn_id, "response_id": response_id, "usage": usage},
    }


def build(home):
    tasks = os.path.join(home, "tasks")
    api = os.path.join(tasks, "t1", "api")
    orch = os.path.join(tasks, "t1")
    research = os.path.join(tasks, "t1", "research")
    other = os.path.join(home, "elsewhere")
    for path in (api, orch, research, other):
        os.makedirs(path, exist_ok=True)
    projects = os.path.join(home, "claude", "projects", "-fixture")
    session_a = os.path.join(projects, "sess-a.jsonl")
    session_b = os.path.join(projects, "sess-b.jsonl")
    sub_b = os.path.join(projects, "sess-b", "subagents", "agent-x.jsonl")

    # Haiku: m-a streams twice (the larger output must win), m-b is over 100k prompt tokens.
    write_lines(session_a, [
        {"type": "user", "sessionId": "sess-a", "cwd": api, "timestamp": "2026-10-15T08:59:00Z"},
        claude_turn("m-a", "claude-haiku-5-5", api, "sess-a", "2026-10-15T09:00:00Z",
                    {"input_tokens": 1000, "output_tokens": 50}),
        claude_turn("m-a", "claude-haiku-5-5", api, "sess-a", "2026-10-15T09:00:02Z",
                    {"input_tokens": 1000, "output_tokens": 200}),
        claude_turn("m-b", "claude-haiku-5-5", api, "sess-a", "2026-10-15T15:00:00Z",
                    {"input_tokens": 500, "cache_read_input_tokens": 120000, "output_tokens": 1000,
                     "cache_creation_input_tokens": 30000,
                     "cache_creation": {"ephemeral_5m_input_tokens": 30000, "ephemeral_1h_input_tokens": 0}}),
        claude_turn("m-old", "claude-haiku-5-5", orch, "sess-a", "2026-10-14T10:00:00Z",
                    {"input_tokens": 1000, "output_tokens": 0}),
        "this line is not json",
        claude_turn("m-s", "<synthetic>", api, "sess-a", "2026-10-15T17:30:00Z",
                    {"input_tokens": 0, "output_tokens": 0}),
    ])
    # Opus (orchestrator, 1h cache write), Haiku at exactly 100k prompt tokens (first tier), interactive.
    write_lines(session_b, [
        claude_turn("m-c", "claude-opus-5-5", orch, "sess-b", "2026-10-15T16:00:00Z",
                    {"input_tokens": 2000, "output_tokens": 400, "cache_read_input_tokens": 10000,
                     "cache_creation_input_tokens": 5000,
                     "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 5000}}),
        claude_turn("m-d", "claude-haiku-5-5", other, "sess-b", "2026-10-15T17:00:00Z",
                    {"input_tokens": 100000, "output_tokens": 0}),
    ])
    # Subagent of sess-b, running in the researcher folder.
    write_lines(sub_b, [
        claude_turn("m-e", "claude-sonnet-5-5", research, "sess-b", "2026-10-15T18:00:00Z",
                    {"input_tokens": 300, "output_tokens": 30}),
    ])

    rollout = os.path.join(home, "codex", "sessions", "2026", "10", "15", "rollout-a.jsonl")
    write_lines(rollout, [
        codex_meta(api, "cx-1"),
        codex_turn("t-1", "gpt-6-luna", api),
        codex_usage("t-1", "r-1", "2026-10-15T19:00:00Z",
                    {"input_tokens": 14990, "cached_input_tokens": 12160, "output_tokens": 14}),
        codex_usage("t-1", "r-1", "2026-10-15T19:00:00Z",
                    {"input_tokens": 14990, "cached_input_tokens": 12160, "output_tokens": 14}),
        codex_turn("t-2", "gpt-6-luna", research),
        codex_usage("t-2", "r-2", "2026-10-15T20:00:00Z",
                    {"input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 5}),
    ])
    return tasks, os.path.join(home, "claude", "projects"), os.path.join(home, "codex", "sessions")


def run(args, tasks, claude, codex, tz="UTC"):
    env = dict(os.environ, TZ=tz)
    command = [sys.executable, "-I", SCRIPT, "--tasks-dir", tasks, "--claude-dir", claude,
               "--codex-dir", codex] + args
    return subprocess.run(command, capture_output=True, text=True, env=env)


def as_json(result):
    if result.returncode != 0:
        fail(f"script exited {result.returncode}: {result.stderr}")
    return json.loads(result.stdout)


def find(rows, **want):
    matches = [row for row in rows if all(row.get(k) == v for k, v in want.items())]
    if len(matches) != 1:
        fail(f"expected one row for {want}, found {len(matches)}")
    return matches[0]


def near(actual, expected, label):
    if actual is None or abs(actual - expected) > 1e-9:
        fail(f"{label}: expected {expected}, got {actual}")


def main():
    with tempfile.TemporaryDirectory() as home:
        tasks, claude, codex = build(home)

        report = as_json(run(["--json"], tasks, claude, codex))
        total = report["total"]
        # Nine responses: 7 Claude (m-a counted once, the <synthetic> one included) and 2 Codex.
        if total["turns"] != 9:
            fail(f"total turns {total['turns']} != 9 (dedupe or counting wrong)")
        if total["sessions"] != 3:
            fail(f"total sessions {total['sessions']} != 3 (sess-a, sess-b, cx-1)")
        if total["unpriced_turns"] != 5:
            fail(f"unpriced turns {total['unpriced_turns']} != 5 (opus, sonnet, synthetic, 2 codex)")
        near(total["cost_usd"], 0.0338, "total priced cost")

        haiku = find(report["by_model"], provider="claude", model="claude-haiku-5-5")
        if haiku["turns"] != 4 or haiku["input"] != 102500 or haiku["output"] != 1200:
            fail(f"haiku tokens wrong: {haiku}")
        if haiku["cache_read"] != 120000 or haiku["cache_write"] != 30000:
            fail(f"haiku cache tokens wrong: {haiku}")
        # Tiers: m-a, m-old and m-d are first-tier; m-b (150.5k prompt) is second-tier.
        near(haiku["cost_usd"], 0.0338, "haiku cost (tiers)")
        opus = find(report["by_model"], provider="claude", model="claude-opus-5-5")
        if opus["cost_usd"] is not None or opus["cache_write"] != 5000:
            fail(f"unpriced opus row wrong: {opus}")
        codex_row = find(report["by_model"], provider="codex", model="gpt-6-luna")
        if codex_row["turns"] != 2 or codex_row["input"] != 2930 or codex_row["cache_read"] != 12160 or codex_row["output"] != 19:
            fail(f"codex tokens wrong (cached input must be split out): {codex_row}")

        by_agent = report["by_agent"]
        orchestrator = find(by_agent, task="t1", role="orchestrator", agent="orchestrator", model="claude-opus-5-5")
        if orchestrator["turns"] != 1:
            fail("orchestrator opus row wrong")
        find(by_agent, task="t1", role="orchestrator", agent="orchestrator", model="claude-haiku-5-5")
        repo = find(by_agent, task="t1", role="repo", agent="api", model="claude-haiku-5-5")
        if repo["turns"] != 2:
            fail(f"repo haiku turns {repo['turns']} != 2")
        near(repo["cost_usd"], 0.0237, "repo haiku cost")
        find(by_agent, task="t1", role="repo", agent="api", provider="codex", model="gpt-6-luna")
        find(by_agent, task="t1", role="researcher", agent="researcher", model="claude-sonnet-5-5")
        find(by_agent, task="t1", role="researcher", agent="researcher", provider="codex", model="gpt-6-luna")
        interactive = find(by_agent, task="-", role="interactive", agent=other_path(home), model="claude-haiku-5-5")
        near(interactive["cost_usd"], 0.01, "interactive haiku cost (exactly 100k prompt tokens)")
        find(report["by_task"], task="t1")
        print("PASS: totals, dedupe, tiers, cache split, codex input split, and attribution by folder")

        # --since is inclusive, --until exclusive; m-b sits exactly at 15:00Z.
        late = as_json(run(["--json", "--since", "2026-10-15T12:00:00Z"], tasks, claude, codex))
        late_haiku = find(late["by_model"], provider="claude", model="claude-haiku-5-5")
        if late_haiku["turns"] != 2:
            fail(f"--since 12:00Z should keep m-b and m-d only, got {late_haiku['turns']}")
        near(late_haiku["cost_usd"], 0.0335, "--since cost")
        early = as_json(run(["--json", "--until", "2026-10-15T12:00:00Z"], tasks, claude, codex))
        early_haiku = find(early["by_model"], provider="claude", model="claude-haiku-5-5")
        if early_haiku["turns"] != 2:
            fail(f"--until 12:00Z should keep m-old and m-a only, got {early_haiku['turns']}")
        excl = as_json(run(["--json", "--until", "2026-10-15T15:00:00Z"], tasks, claude, codex))
        if find(excl["by_model"], provider="claude", model="claude-haiku-5-5")["turns"] != 2:
            fail("--until must exclude a response stamped exactly at that time")
        print("PASS: --since is inclusive and --until exclusive, relative to the stamps")

        # A zone-less time is local time: 14:00 at UTC-3 is 17:00Z, so only m-d (17:00Z) is kept.
        naive = as_json(run(["--json", "--since", "2026-10-15T14:00"], tasks, claude, codex, tz="Etc/GMT+3"))
        naive_haiku = find(naive["by_model"], provider="claude", model="claude-haiku-5-5")
        if naive_haiku["turns"] != 1:
            fail(f"zone-less --since was not read as local time: {naive_haiku['turns']} turns")
        print("PASS: zone-less --since/--until read as local time")

        # Missing folders and an empty range are fine; reversed range is an error.
        empty = as_json(run(["--json", "--codex-dir", os.path.join(home, "nope")], tasks, claude,
                            os.path.join(home, "nope")))
        if empty["total"]["turns"] != 7:
            fail("missing codex folder should leave only the claude responses")
        if run(["--since", "2026-10-16", "--until", "2026-10-15"], tasks, claude, codex).returncode == 0:
            fail("--since after --until was accepted")
        print("PASS: missing folders are empty, not errors; reversed range is refused")

        text = run([], tasks, claude, codex)
        if text.returncode != 0:
            fail(f"table run failed: {text.stderr}")
        for needle in ("Per task", "Per agent and model", "Per model", "n/a", "not billing data",
                       "bad lines skipped: 1"):
            if needle not in text.stdout:
                fail(f"table output lacks {needle!r}")
        if "bad lines" not in text.stdout or "warning" not in text.stderr:
            fail("bad JSON line was not reported")
        print("PASS: table output labels estimates, n/a prices and skipped lines")


def other_path(home):
    return os.path.realpath(os.path.join(home, "elsewhere"))


if __name__ == "__main__":
    main()
    print("agent-usage fixture passed")
