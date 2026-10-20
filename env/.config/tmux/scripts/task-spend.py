#!/usr/bin/env python3
"""Spend and efficiency for the task agents (contracts C1 and C2), from Claude Code and Codex transcripts.

    task-spend.py [--since WHEN] [--until WHEN] [--by day|task] [--json]
                  [--split WHEN] [--prices FILE]
                  [--efficiency [--group role|model|task|role,task|session]]
                  [--state FILE --by node|attempt|tier]
                  [--claude-dir DIR] [--codex-dir DIR] [--tasks-dir DIR]

Reads <claude-dir>/**/*.jsonl (subagent sidechains included) and <codex-dir>/**/*.jsonl
when present. Read-only: writes nothing, no network. Each API response counts once:
Claude streams one message as several records with the same message id, and the
largest count seen for each field is kept; its tool_use blocks are counted by id. Codex responses
come from token_usage_record (or token_count events when a rollout has none); their tool calls are
the function_call and custom_tool_call items before each response. Cached input is priced apart.

A response's task and role come from the cwd it ran in: <tasks>/<task> is the
orchestrator, <tasks>/<task>/research the researcher, <tasks>/<task>/<repo> worker-<repo>,
anything else other. Subagent (sidechain) responses have role subagent and keep their task.

Costs are list-price estimates from PRICES, not billing data. A model with no price is
counted in tokens with its cost left out, and is named on stderr. cost_usd sums only the
priced responses; unpriced_turns counts the ones left out.

WHEN is YYYY-MM-DD or an ISO date-time with optional zone; zone-less values are local time.
--since is inclusive, --until exclusive. --by task sums over days. --split WHEN prints, per
role, the active days, sessions and USD per day and per session before and after WHEN
(text only). --json prints the rows as a list.

--efficiency prints, per group, sessions, turns (API responses), tasks, tokens and USD by
kind (cache writes split 5m and 1h), USD per turn, session and task, prompt size per turn
(input + cache read + cache write), cache hit and write share, tool calls per turn and the
share of turns in a price tier above the first. The task group adds the orchestrator's share
of task USD and worker turns per orchestrator turn. With --split it prints the tables before
and after WHEN (text only).

--state FILE reads one task's state.db (read-only) and prints spend per node, per attempt or per
tier (--by node|attempt|tier; node is the default). A response counts for the attempt of its agent
(worker-<repo> or researcher; a subagent counts under the agent whose worktree it ran in) whose
window [started_at, ended_at or now] holds it, the latest-started one when they overlap. The
orchestrator's responses from the task's first dispatcher event on are tier T2. jev judgement cost
is judgements.cost_usd, tier T1.
"""
import argparse
import bisect
import collections
import datetime
import functools
import glob
import json
import math
import os
import sqlite3
import sys
import time

# USD per million tokens: Claude API list prices from the claude-api skill, cached 2026-10-06
# (prompts/prices.json in the task root). A model's tiers are picked by its response's prompt
# size (input + cache tokens): the first tier whose upto holds it; the last tier has upto null.
# Codex prices are list-price equivalents (plan-billed) from the same file, tiered at 272k prompt tokens.
# codex-auto-review has no official price: it carries gpt-6-luna's rates as a placeholder.
PRICES = {
    "claude-opus-5-5": [
        {"upto": None, "input": 4.00, "output": 20.00, "cache_read": 0.20,
         "cache_write_5m": 5.00, "cache_write_1h": 8.00},
    ],
    "claude-opus-5": [
        {"upto": None, "input": 5.00, "output": 25.00, "cache_read": 0.50,
         "cache_write_5m": 6.25, "cache_write_1h": 10.00},
    ],
    "claude-sonnet-5-5": [
        {"upto": None, "input": 2.00, "output": 10.00, "cache_read": 0.20,
         "cache_write_5m": 2.50, "cache_write_1h": 4.00},
    ],
    "claude-haiku-5-5": [
        {"upto": 100_000, "input": 0.10, "output": 0.50, "cache_read": 0.01,
         "cache_write_5m": 0.125, "cache_write_1h": 0.20},
        {"upto": None, "input": 0.50, "output": 2.50, "cache_read": 0.05,
         "cache_write_5m": 0.625, "cache_write_1h": 1.00},
    ],
    "claude-fable-5-1": [
        {"upto": None, "input": 10.00, "output": 50.00, "cache_read": 0.25,
         "cache_write_5m": 12.50, "cache_write_1h": 20.00},
    ],
    "gpt-6-astra": [
        {"upto": 272000, "input": 10, "output": 50, "cache_read": 1.0, "cache_write_5m": 0, "cache_write_1h": 0},
        {"upto": None, "input": 20, "output": 75, "cache_read": 2.0, "cache_write_5m": 0, "cache_write_1h": 0},
    ],
    "gpt-6.1-sol": [
        {"upto": 272000, "input": 2, "output": 10, "cache_read": 0.1, "cache_write_5m": 0, "cache_write_1h": 0},
        {"upto": None, "input": 4, "output": 15, "cache_read": 0.2, "cache_write_5m": 0, "cache_write_1h": 0},
    ],
    "gpt-6-luna": [
        {"upto": 272000, "input": 0.1, "output": 0.5, "cache_read": 0.01, "cache_write_5m": 0, "cache_write_1h": 0},
        {"upto": None, "input": 0.2, "output": 0.75, "cache_read": 0.02, "cache_write_5m": 0, "cache_write_1h": 0},
    ],
    "codex-auto-review": [
        {"upto": 272000, "input": 0.1, "output": 0.5, "cache_read": 0.01, "cache_write_5m": 0, "cache_write_1h": 0},
        {"upto": None, "input": 0.2, "output": 0.75, "cache_read": 0.02, "cache_write_5m": 0, "cache_write_1h": 0},
    ],
    # jev judgements (task_jev.py): input only, the list price task-dispatch records; output is not reported.
    "typesafe/jev-1.14": [
        {"upto": None, "input": 0.042, "output": 0, "cache_read": 0, "cache_write_5m": 0, "cache_write_1h": 0},
    ],
}
JUDGE_PROVIDER = "jev"
JUDGE_FALLBACK_MODEL = "typesafe/jev-1.14"  # the price a judgement row falls back to when its model has none
TOKEN_FIELDS = ("input", "output", "cache_read", "cache_write_5m", "cache_write_1h")
CODEX_TOOL_ITEMS = ("function_call", "custom_tool_call")
GROUPS = {"role": ("role",), "model": ("model",), "task": ("task",), "role,task": ("role", "task"),
          "session": ("session",)}
# Session rows name the session and the task and role of its first response.
LABELS = {"session": ("session", "task", "role")}


def parse_when(text):
    try:
        if len(text) == 10:
            value = datetime.datetime.strptime(text, "%Y-%m-%d")
        else:
            value = datetime.datetime.fromisoformat(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a date or date-time: {text}")
    return value.astimezone() if value.tzinfo is None else value


def parse_ts(text):
    try:
        value = datetime.datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return None
    return value if value.tzinfo else value.astimezone()


def as_dict(value):
    return value if isinstance(value, dict) else {}


def num(value):
    return int(value or 0)


def read_lines(path, counts):
    """Parsed JSON values of a file; unreadable lines are counted, not fatal."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    yield json.loads(line)
                except ValueError:
                    counts["bad_lines"] += 1
    except OSError:
        counts["unreadable_files"] += 1


def claude_responses(root, counts):
    for path in sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)):
        subagent_file = "subagents" in path.split(os.sep)
        for number, record in enumerate(read_lines(path, counts)):
            if not isinstance(record, dict) or record.get("type") != "assistant":
                continue
            message = as_dict(record.get("message"))
            usage = as_dict(message.get("usage"))
            split = as_dict(usage.get("cache_creation"))
            write_5m = num(split.get("ephemeral_5m_input_tokens"))
            write_1h = num(split.get("ephemeral_1h_input_tokens"))
            unsplit = not write_5m and not write_1h and num(usage.get("cache_creation_input_tokens")) > 0
            if unsplit:
                write_5m = num(usage.get("cache_creation_input_tokens"))
            blocks = message.get("content")
            content = blocks if isinstance(blocks, list) else []
            tool_ids = {
                block.get("id") or f"{path}:{number}:{index}"
                for index, block in enumerate(content)
                if isinstance(block, dict) and block.get("type") == "tool_use"
            }
            yield {
                "provider": "claude",
                "key": message.get("id") or f"{path}:{number}",
                "ts": parse_ts(record.get("timestamp")),
                "cwd": record.get("cwd"),
                "session": record.get("sessionId") or path,
                "model": message.get("model") or "unknown",
                "sidechain": record.get("isSidechain") is True or subagent_file,
                "input": num(usage.get("input_tokens")),
                "output": num(usage.get("output_tokens")),
                "cache_read": num(usage.get("cache_read_input_tokens")),
                "cache_write_5m": write_5m,
                "cache_write_1h": write_1h,
                "write_unsplit": unsplit,
                "tool_ids": tool_ids,
            }


def codex_response(path, stamp, response_id, session, model, cwd, usage, tools):
    cached = num(usage.get("cached_input_tokens"))
    cache_write = num(usage.get("cache_write_input_tokens"))
    return {
        "provider": "codex",
        "key": response_id or f"{path}:{stamp}",
        "ts": parse_ts(stamp),
        "cwd": cwd,
        "session": session or path,
        "model": model or "unknown",
        "sidechain": False,
        # input_tokens includes the cached part, which is priced apart; reasoning is inside output_tokens.
        "input": max(num(usage.get("input_tokens")) - cached, 0),
        "output": num(usage.get("output_tokens")),
        "cache_read": cached,
        "cache_write_5m": cache_write,
        "cache_write_1h": 0,
        "write_unsplit": cache_write > 0,
        "tool_ids": set(tools),
    }


def codex_responses(root, counts):
    """Responses of each rollout. token_usage_record (one per response) is preferred. A rollout without
    any uses its token_count events instead: last_token_usage is the per-call delta, and a repeated total
    is skipped. A tool item sits just before its response's record, so a response takes the tool items
    since the previous record (or token_count)."""
    for path in sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)):
        turns, records, counted = {}, [], []
        cwd, session, model_now, cwd_now = None, None, None, None
        pending_records, pending_counts = set(), set()
        for number, record in enumerate(read_lines(path, counts)):
            if not isinstance(record, dict):
                continue
            payload = as_dict(record.get("payload"))
            kind = record.get("type")
            if kind == "response_item" and payload.get("type") in CODEX_TOOL_ITEMS:
                pending_records.add(f"{path}:{number}")
                pending_counts.add(f"{path}:{number}")
            elif kind == "session_meta":
                cwd = payload.get("cwd") or cwd
                session = payload.get("session_id") or payload.get("id") or session
            elif kind == "turn_context":
                turns[payload.get("turn_id")] = (payload.get("model"), payload.get("cwd"))
                model_now, cwd_now = payload.get("model"), payload.get("cwd")
            elif kind == "token_usage_record":
                records.append((record, pending_records))
                pending_records = set()
            elif kind == "event_msg" and payload.get("type") == "token_count":
                counted.append((record, pending_counts, model_now, cwd_now))
                pending_counts = set()
        if records:
            for record, tools in records:
                payload = as_dict(record.get("payload"))
                model, turn_cwd = turns.get(payload.get("turn_id"), (None, None))
                yield codex_response(path, record.get("timestamp"), payload.get("response_id"),
                                     payload.get("session_id") or session, model, turn_cwd or cwd,
                                     as_dict(payload.get("usage")), tools)
            continue
        previous = None
        for record, tools, model, turn_cwd in counted:
            info = as_dict(as_dict(record.get("payload")).get("info"))
            total = info.get("total_token_usage")
            if not total or total == previous:
                continue
            previous = total
            yield codex_response(path, record.get("timestamp"), None, session, model, turn_cwd or cwd,
                                 as_dict(info.get("last_token_usage")), tools)


def judgement_responses(tasks):
    """One response per jev judgement with input tokens, read from each task root's state.db (read-only). Role judge,
    one session per judged attempt; a task root with no judgements table gives nothing."""
    rows = []
    noted = set()  # models already reported as unpriced on stderr
    for path in sorted(glob.glob(os.path.join(tasks, "*", "state.db"))):
        task = os.path.basename(os.path.dirname(path))
        try:
            conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        except sqlite3.Error:
            continue
        try:
            found = conn.execute(
                "SELECT node, attempt, model, input_tokens, judged_at FROM judgements WHERE input_tokens IS NOT NULL"
            ).fetchall()
        except sqlite3.Error:
            found = []
        finally:
            conn.close()
        for node, attempt, model, tokens, judged_at in found:
            key = f"{task}/{node}/{attempt}"
            if model not in PRICES and model not in noted:  # a TASK_JEV_MODEL override with no price of its own
                noted.add(model)
                print(f"note: {model} has no price; its judgements are priced as {JUDGE_FALLBACK_MODEL}", file=sys.stderr)
            rows.append({
                "provider": JUDGE_PROVIDER, "key": key, "session": key, "task": task, "role": "judge", "model": model,
                "price_model": model if model in PRICES else JUDGE_FALLBACK_MODEL,
                "cwd": "", "sidechain": False, "tool_ids": set(), "write_unsplit": 0, "output": 0, "cache_read": 0,
                "cache_write_5m": 0, "cache_write_1h": 0, "input": tokens,
                "ts": datetime.datetime.fromtimestamp(judged_at, datetime.timezone.utc).astimezone() if judged_at else None,
            })
    return rows


def merge_responses(responses):
    """One entry per API response; streamed copies keep the largest count of each field."""
    merged = {}
    for response in responses:
        key = (response["provider"], response["key"])
        kept = merged.get(key)
        if kept is None:
            merged[key] = response
            continue
        for field in TOKEN_FIELDS:
            kept[field] = max(kept[field], response[field])
        kept["ts"] = kept["ts"] or response["ts"]
        kept["tool_ids"] |= response["tool_ids"]
    return list(merged.values())


@functools.lru_cache(maxsize=None)
def real_path(path):
    return os.path.realpath(path)


def attribute(cwd, sidechain, tasks):
    """(task, role) of a response from the directory it ran in."""
    task, role = "-", "other"
    if cwd and real_path(cwd).startswith(tasks + os.sep):
        parts = real_path(cwd)[len(tasks) + 1:].split(os.sep)
        task = parts[0]
        if len(parts) == 1:
            role = "orchestrator"
        elif parts[1] == "research":
            role = "researcher"
        else:
            role = f"worker-{parts[1]}"
    if sidechain:
        role = "subagent"
    return task, role


def prompt_size(response):
    return response["input"] + response["cache_read"] + response["cache_write_5m"] + response["cache_write_1h"]


def price_turn(response, prices):
    """(USD by token kind, tier index) for one response, or (None, None) when its model has no price."""
    for index, tier in enumerate(prices.get(response.get("price_model", response["model"])) or ()):
        if tier["upto"] is None or prompt_size(response) <= tier["upto"]:
            return {field: response[field] * tier[field] / 1_000_000 for field in TOKEN_FIELDS}, index
    return None, None


def load_prices(path):
    """PRICES with the models in the JSON object at path replaced: {model: [tier, ...] or null}."""
    with open(path, encoding="utf-8") as handle:
        overrides = json.load(handle)
    if not isinstance(overrides, dict):
        raise ValueError("the file must hold a JSON object")
    for model, tiers in overrides.items():
        for tier in tiers or ():
            if not all(field in tier for field in ("upto",) + TOKEN_FIELDS):
                raise ValueError(f"{model}: each tier needs upto and {', '.join(TOKEN_FIELDS)}")
    return {**PRICES, **overrides}


def fold(responses):
    """C1 totals of a set of responses: sessions as a distinct count, cost of the priced ones."""
    total = {"sessions": set(), "cost": 0.0, "unpriced_turns": 0, **dict.fromkeys(TOKEN_FIELDS, 0)}
    for response in responses:
        total["sessions"].add((response["provider"], response["session"]))
        for field in TOKEN_FIELDS:
            total[field] += response[field]
        if response["cost"] is None:
            total["unpriced_turns"] += 1
        else:
            total["cost"] += response["cost"]
    return {
        "sessions": len(total["sessions"]),
        "input_tokens": total["input"],
        "output_tokens": total["output"],
        "cache_read_tokens": total["cache_read"],
        "cache_write_tokens": total["cache_write_5m"] + total["cache_write_1h"],
        "cost_usd": round(total["cost"], 6),
        "unpriced_turns": total["unpriced_turns"],
    }


def rows_by(responses, by):
    groups = collections.defaultdict(list)
    for response in responses:
        key = (response["date"] if by == "day" else None, response["task"], response["role"], response["model"])
        groups[key].append(response)
    ordered = sorted(groups.items(), key=lambda item: tuple(part or "" for part in item[0]))
    return [{"date": d, "task": t, "role": r, "model": m, **fold(group)} for (d, t, r, m), group in ordered]


def split_rows(responses, when):
    rows = []
    for role in sorted({response["role"] for response in responses}):
        row = {"role": role}
        for period in ("before", "after"):
            picked = [
                response for response in responses
                if response["role"] == role and ((response["ts"] < when) == (period == "before"))
            ]
            total = fold(picked)
            days = len({response["date"] for response in picked})
            row[f"{period}_days"] = days
            row[f"{period}_sessions"] = total["sessions"]
            row[f"{period}_usd_per_day"] = total["cost_usd"] / days if days else None
            row[f"{period}_usd_per_session"] = total["cost_usd"] / total["sessions"] if total["sessions"] else None
        rows.append(row)
    return rows


def ratio(top, bottom):
    return top / bottom if bottom else None


def group_labels(group):
    return LABELS[group] if group in LABELS else GROUPS[group]


def efficiency_row(group, members):
    """C2 figures for one group of responses. USD per turn, session and task use the priced turns."""
    labels = group_labels(group)
    row = {name: members[0][name] for name in labels}
    priced = [response for response in members if response["cost"] is not None]
    tiered = [response for response in members if response["tiered"]]
    long_tier = [response for response in tiered if response["tier"] > 0]
    tokens = {field: sum(response[field] for response in members) for field in TOKEN_FIELDS}
    prompts = sorted(prompt_size(response) for response in members)
    prompt_total = sum(prompts)
    sessions = {(response["provider"], response["session"]) for response in members}
    cost = sum(response["cost"] for response in priced) if priced else None
    row.update(
        sessions=len(sessions),
        turns=len(members),
        tasks=len({response["task"] for response in members}),
        turns_per_session=ratio(len(members), len(sessions)),
        tool_calls_per_turn=ratio(sum(len(response["tool_ids"]) for response in members), len(members)),
        unpriced_turns=len(members) - len(priced),
        long_tier_turns=len(long_tier),
        long_tier_share=ratio(len(long_tier), len(tiered)),
        long_tier_usd=sum(response["cost"] for response in long_tier) if long_tier else None,
        output_per_turn=ratio(tokens["output"], len(members)),
        prompt_avg=ratio(prompt_total, len(members)),
        prompt_p95=prompts[max(0, math.ceil(0.95 * len(prompts)) - 1)],
        cache_hit=ratio(tokens["cache_read"], prompt_total),
        write_share=ratio(tokens["cache_write_5m"] + tokens["cache_write_1h"], prompt_total),
        cost_usd=cost,
        usd_per_turn=ratio(cost, len(priced)),
        usd_per_session=ratio(cost, len({(response["provider"], response["session"]) for response in priced})),
        usd_per_task=ratio(cost, len({response["task"] for response in priced})),
        unsplit_write_turns=sum(response["write_unsplit"] for response in members),
    )
    for field in TOKEN_FIELDS:
        row[f"{field}_tokens"] = tokens[field]
        row[f"usd_{field}"] = sum(response["cost_by_kind"][field] for response in priced) if priced else None
    if group == "task":
        orchestrator = sum(response["cost"] for response in priced if response["role"] == "orchestrator")
        row["orchestrator_usd_share"] = ratio(orchestrator, cost)
        row["worker_turns_per_orchestrator_turn"] = ratio(
            sum(response["role"].startswith("worker-") for response in members),
            sum(response["role"] == "orchestrator" for response in members),
        )
    return row


def efficiency_rows(responses, group):
    groups = collections.defaultdict(list)
    for response in responses:
        groups[tuple(response[name] for name in GROUPS[group])].append(response)
    return [efficiency_row(group, members) for _, members in sorted(groups.items())]


def read_state(path):
    """Attempts (node, attempt, agent, started_at, ended_at), judgements (node, attempt, cost_usd, judged_at) and the
    task's first event time, from state.db, read-only. A running attempt has no ended_at."""
    conn = sqlite3.connect(f"file:{real_path(path)}?mode=ro", uri=True)
    try:
        attempts = conn.execute(
            "SELECT a.node, a.attempt, n.agent, a.started_at, a.ended_at FROM attempts a "
            "JOIN nodes n ON n.id = a.node WHERE a.started_at IS NOT NULL ORDER BY a.node, a.attempt"
        ).fetchall()
        judged = conn.execute("SELECT node, attempt, cost_usd, judged_at FROM judgements").fetchall()
        first = conn.execute("SELECT MIN(ts) FROM events").fetchone()[0]
    finally:
        conn.close()
    return attempts, judged, first


def in_span(when, since, until):
    """Whether an epoch time is in [since, until); either bound may be None."""
    return (since is None or when >= since.timestamp()) and (until is None or when < until.timestamp())


def attempt_spend(responses, state, tasks, since, until, now):
    """Spend of one task's attempts, from the priced responses and state.db. Returns the parts spend_rows reads:
    attempts (one dict each), orchestrator and unattributed as [turns, USD] (the orchestrator's T2 turns, and the
    usage no window holds), and judge as [judgements, jev USD]."""
    task = os.path.basename(os.path.dirname(real_path(state)))
    attempts, judged, first = read_state(state)
    windows = collections.defaultdict(list)
    for node, attempt, agent, started, ended in attempts:
        windows[agent].append((started, now if ended is None else ended, node, attempt))
    for held in windows.values():
        held.sort()
    usage = collections.defaultdict(lambda: [0, 0.0])
    orchestrator, unattributed = [0, 0.0], [0, 0.0]
    for response in responses:
        if response["provider"] == JUDGE_PROVIDER or response["task"] != task or response["ts"] is None:
            continue
        agent = attribute(response["cwd"], False, tasks)[1] if response["role"] == "subagent" else response["role"]
        when, cost = response["ts"].timestamp(), response["cost"] or 0.0
        if agent == "orchestrator" and first is not None and when >= first:
            orchestrator[0] += 1
            orchestrator[1] += cost
            continue
        held = windows.get(agent, [])
        index = bisect.bisect_right(held, (when, math.inf))
        window = held[index - 1] if index else None
        if agent != "orchestrator" and window and window[1] >= when:
            bucket = usage[(window[2], window[3])]
        else:
            bucket = unattributed
        bucket[0] += 1
        bucket[1] += cost
    jev, judges = collections.defaultdict(float), [0, 0.0]
    for node, attempt, cost, judged_at in judged:
        if (since or until) and (judged_at is None or not in_span(judged_at, since, until)):
            continue
        jev[(node, attempt)] += cost or 0.0
        judges[0] += 1
        judges[1] += cost or 0.0
    rows = []
    for node, attempt, agent, _, _ in attempts:
        turns, usd = usage.get((node, attempt), (0, 0.0))
        rows.append({"node": node, "attempt": attempt, "agent": agent, "tier": "work", "turns": turns,
                     "usd": usd, "jev_usd": jev.get((node, attempt), 0.0)})
    return {"attempts": rows, "orchestrator": orchestrator, "unattributed": unattributed, "judge": judges}


def spend_rows(parts, by):
    """Rows for --by node (per node), attempt (per attempt) or tier (work, T1 judge, T2 orchestrator). Each row:
    node, attempt, agent, tier, turns, usd (the tier's or the agent's own spend) and jev_usd (the judge's cost)."""
    def row(node, attempt, agent, tier, turns, usd, jev_usd=0.0):
        return {"node": node, "attempt": attempt, "agent": agent, "tier": tier, "turns": turns, "usd": usd,
                "jev_usd": jev_usd}

    orchestrator = row("-", None, "orchestrator", "T2", *parts["orchestrator"])
    unattributed = [row("-", None, "-", "unattributed", *parts["unattributed"])] if parts["unattributed"][0] else []
    if by == "tier":
        work = [0, 0.0]
        for item in parts["attempts"]:
            work[0] += item["turns"]
            work[1] += item["usd"]
        judge = row("-", None, "jev", "T1", *parts["judge"])
        return [row("-", None, "-", "work", *work), judge, orchestrator] + unattributed
    if by == "attempt":
        return parts["attempts"] + [orchestrator] + unattributed
    per_node = {}
    for item in parts["attempts"]:
        total = per_node.setdefault(item["node"], row(item["node"], None, item["agent"], "work", 0, 0.0))
        total["turns"] += item["turns"]
        total["usd"] += item["usd"]
        total["jev_usd"] += item["jev_usd"]
    return list(per_node.values()) + [orchestrator] + unattributed


def cell(value, kind):
    if value is None:
        return "-"
    if kind == "text":
        return str(value)
    if kind == "int":
        return f"{value:,}"
    if kind == "tok":
        if value >= 1_000_000:
            return f"{value / 1_000_000:.2f}M"
        if value >= 1_000:
            return f"{value / 1_000:.1f}k"
        return f"{value:,.0f}"
    if kind == "usd":
        return f"${value:,.2f}"
    if kind == "usd4":
        return f"{value:,.4f}"
    if kind == "pct":
        return f"{value:.1%}"
    if kind == "ratio":
        return f"{value:,.2f}"
    raise ValueError(kind)


def print_table(columns, rows, out):
    """columns: (header, key, kind) triples. Text columns are left-aligned, the rest right-aligned."""
    cells = [[header for header, _, _ in columns]]
    cells += [[cell(row.get(key), kind) for _, key, kind in columns] for row in rows]
    widths = [max(len(line[i]) for line in cells) for i in range(len(columns))]
    for line in cells:
        justified = [
            text.ljust(width) if kind == "text" else text.rjust(width)
            for (_, _, kind), text, width in zip(columns, line, widths)
        ]
        print("  ".join(justified).rstrip(), file=out)


ROW_COLUMNS = [
    ("date", "date", "text"), ("task", "task", "text"), ("role", "role", "text"), ("model", "model", "text"),
    ("sessions", "sessions", "int"), ("input", "input_tokens", "int"), ("output", "output_tokens", "int"),
    ("cache read", "cache_read_tokens", "int"), ("cache write", "cache_write_tokens", "int"),
    ("USD", "cost_usd", "usd4"), ("unpriced", "unpriced_turns", "int"),
]
SPLIT_COLUMNS = [("role", "role", "text")] + [
    (f"{period} {name}", f"{period}_{key}", kind)
    for period in ("before", "after")
    for name, key, kind in (("days", "days", "int"), ("sessions", "sessions", "int"),
                            ("USD/day", "usd_per_day", "usd4"), ("USD/session", "usd_per_session", "usd4"))
]
EFFICIENCY_TABLES = [
    ("volume", [
        ("sessions", "sessions", "int"), ("turns", "turns", "int"), ("tasks", "tasks", "int"),
        ("turns/session", "turns_per_session", "ratio"), ("tool calls/turn", "tool_calls_per_turn", "ratio"),
        ("unpriced", "unpriced_turns", "int"), ("long-tier turns", "long_tier_turns", "int"),
        ("long share", "long_tier_share", "pct"), ("long-tier USD", "long_tier_usd", "usd"),
    ]),
    ("tokens", [
        ("input", "input_tokens", "tok"), ("output", "output_tokens", "tok"),
        ("cache read", "cache_read_tokens", "tok"), ("write 5m", "cache_write_5m_tokens", "tok"),
        ("write 1h", "cache_write_1h_tokens", "tok"), ("output/turn", "output_per_turn", "tok"),
    ]),
    ("USD (Codex: list-price equivalent (plan-billed))", [
        ("USD", "cost_usd", "usd"), ("input", "usd_input", "usd"), ("output", "usd_output", "usd"),
        ("cache read", "usd_cache_read", "usd"), ("write 5m", "usd_cache_write_5m", "usd"),
        ("write 1h", "usd_cache_write_1h", "usd"), ("USD/turn", "usd_per_turn", "usd"),
        ("USD/session", "usd_per_session", "usd"), ("USD/task", "usd_per_task", "usd"),
    ]),
    ("prompt per turn", [
        ("avg", "prompt_avg", "tok"), ("p95", "prompt_p95", "tok"),
        ("cache hit", "cache_hit", "pct"), ("write share", "write_share", "pct"),
    ]),
]
TASK_TABLE = ("per task", [
    ("orchestrator share of USD", "orchestrator_usd_share", "pct"),
    ("worker turns/orchestrator turn", "worker_turns_per_orchestrator_turn", "ratio"),
])
EFFICIENCY_NOTES = [
    "USD is a list-price estimate (Claude) or list-price equivalent (plan-billed, Codex). Per turn, session and "
    "task it covers priced turns only (see unpriced).",
    "tool calls/turn counts Claude tool_use blocks and Codex function_call and custom_tool_call items.",
    "prompt = input + cache read + cache write; cache hit = cache read / prompt; write share = cache write / prompt; "
    "p95 is nearest-rank.",
    "long tier: turns priced above the first tier (Haiku over 100k prompt tokens, Codex over 272k); long share is "
    "over tiered turns.",
    "worker turns are roles worker-<repo>; the researcher and subagents are left out.",
]


def print_efficiency(rows, group, out):
    labels = group_labels(group)
    tables = EFFICIENCY_TABLES + ([TASK_TABLE] if group == "task" else [])
    for title, columns in tables:
        print(title, file=out)
        print_table([(name, name, "text") for name in labels] + columns, rows, out)
        print(file=out)


ATTEMPT_COLUMNS = [
    ("node", "node", "text"), ("attempt", "attempt", "int"), ("agent", "agent", "text"), ("tier", "tier", "text"),
    ("turns", "turns", "int"), ("USD", "usd", "usd4"), ("jev USD", "jev_usd", "usd4"),
]
STATE_BY = ("node", "attempt", "tier")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Spend and efficiency for the task agents (contracts C1, C2).")
    parser.add_argument("--since", type=parse_when, help="responses at or after this time")
    parser.add_argument("--until", type=parse_when, help="responses before this time (exclusive)")
    parser.add_argument("--by", choices=["day", "task", *STATE_BY],
                        help="rows per day (default), or per task over all days (date is then '-'); with --state, "
                             "per node (default), attempt or tier")
    parser.add_argument("--state", metavar="FILE", help="a task's state.db: spend per node, attempt or tier")
    parser.add_argument("--split", type=parse_when, metavar="WHEN",
                        help="per-role averages before and after WHEN; with --efficiency, the tables (text only)")
    parser.add_argument("--json", action="store_true", help="print the rows as a JSON list")
    parser.add_argument("--efficiency", action="store_true", help="efficiency tables instead of spend rows")
    parser.add_argument("--group", choices=sorted(GROUPS), help="efficiency rows per group (default role)")
    parser.add_argument("--prices", metavar="FILE", help="JSON object of model -> tiers (or null), overriding PRICES")
    parser.add_argument("--claude-dir", default=os.path.expanduser("~/.claude/projects"))
    parser.add_argument("--codex-dir", default=os.path.expanduser("~/.codex/sessions"))
    parser.add_argument("--tasks-dir", default=os.path.expanduser("~/tasks"))
    args = parser.parse_args(argv)
    if args.since and args.until and args.since >= args.until:
        parser.error("--since must be before --until")
    if args.split and args.json:
        parser.error("--split prints text only")
    if args.by and args.efficiency:
        parser.error("--by applies to spend rows, not --efficiency")
    if args.group and not args.efficiency:
        parser.error("--group needs --efficiency")
    if args.state:
        if args.split or args.efficiency:
            parser.error("--state does not combine with --split or --efficiency")
        if not os.path.isfile(args.state):
            parser.error(f"--state: no such file: {args.state}")
        args.by = args.by or "node"
        if args.by not in STATE_BY:
            parser.error("--state goes with --by node, attempt or tier")
    elif args.by in STATE_BY:
        parser.error("--by node, attempt and tier need --state")
    try:
        prices = load_prices(args.prices) if args.prices else PRICES
    except (OSError, ValueError) as error:
        parser.error(f"--prices: {error}")

    counts = collections.Counter()
    tasks = real_path(args.tasks_dir)
    merged = merge_responses(
        list(claude_responses(args.claude_dir, counts)) + list(codex_responses(args.codex_dir, counts))
    ) + judgement_responses(tasks)
    responses = []
    for response in merged:
        if not sum(response[field] for field in TOKEN_FIELDS):
            continue
        ts = response["ts"]
        if (args.since or args.until) and ts is None:
            continue
        if args.since and ts < args.since:
            continue
        if args.until and ts >= args.until:
            continue
        response["date"] = ts.astimezone().date().isoformat() if ts else "-"
        if response["provider"] != JUDGE_PROVIDER:
            response["task"], response["role"] = attribute(response["cwd"], response["sidechain"], tasks)
        response["cost_by_kind"], response["tier"] = price_turn(response, prices)
        response["cost"] = sum(response["cost_by_kind"].values()) if response["cost_by_kind"] else None
        response["tiered"] = len(prices.get(response["model"]) or ()) > 1
        responses.append(response)

    unsplit = sum(response["write_unsplit"] for response in responses)
    notes = [f"cache writes with no 5m/1h split: {unsplit} response(s), counted as 5m."] if unsplit else []
    if any(response["provider"] == JUDGE_PROVIDER for response in responses):
        notes.append("jev judgements (role judge): input tokens only, from each task's state.db; jev output is not counted.")
    if any(response["provider"] == "codex" for response in responses):
        notes.append("Codex USD is a list-price equivalent (plan-billed).")
    if any(response["model"] == "codex-auto-review" for response in responses):
        notes.append("codex-auto-review has no official price: it is priced at gpt-6-luna rates as a placeholder.")
    if args.state:
        try:
            parts = attempt_spend(responses, args.state, tasks, args.since, args.until, time.time())
        except sqlite3.Error as error:
            parser.error(f"--state: {error}")
        if args.json:
            json.dump(spend_rows(parts, args.by), sys.stdout, indent=2)
            sys.stdout.write("\n")
        else:
            print_table(ATTEMPT_COLUMNS, spend_rows(parts, args.by), sys.stdout)
            print("* usd is the agent's own turns inside its attempt windows (a subagent counts under the agent whose "
                  "worktree it ran in); jev USD is the judge's cost_usd for the attempt.")
            print("* tier work is the attempts, T1 the judge, T2 the orchestrator from the task's first event on "
                  "(window end: now); unattributed is usage no window or T2 holds.")
            for note in notes:
                print(f"* {note}")
    elif args.efficiency:
        group = args.group or "role"
        if args.split:
            timed = [response for response in responses if response["ts"] is not None]
            for label, picked in (
                ("before", [response for response in timed if response["ts"] < args.split]),
                ("after", [response for response in timed if response["ts"] >= args.split]),
            ):
                print(f"{label} {args.split.isoformat()}")
                print_efficiency(efficiency_rows(picked, group), group, sys.stdout)
        elif args.json:
            json.dump(efficiency_rows(responses, group), sys.stdout, indent=2)
            sys.stdout.write("\n")
        else:
            print_efficiency(efficiency_rows(responses, group), group, sys.stdout)
        if not args.json:
            for note in EFFICIENCY_NOTES + notes:
                print(f"* {note}")
    elif args.split:
        timed = [response for response in responses if response["ts"] is not None]
        print(f"split at {args.split.isoformat()}: before is earlier, after is from that time")
        print_table(SPLIT_COLUMNS, split_rows(timed, args.split), sys.stdout)
        for note in notes:
            print(f"* {note}")
    elif args.json:
        json.dump(rows_by(responses, args.by or "day"), sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        rows = rows_by(responses, args.by or "day")
        print_table(ROW_COLUMNS, rows + [{"date": "total", "task": "", "role": "", "model": "", **fold(responses)}],
                    sys.stdout)
        for note in notes:
            print(f"* {note}")

    unpriced = sorted({response["model"] for response in responses if response["cost"] is None})
    if unpriced:
        print(f"unpriced models (tokens counted, cost left out): {', '.join(unpriced)}", file=sys.stderr)
    if counts["bad_lines"] or counts["unreadable_files"]:
        print(f"warning: skipped {counts['bad_lines']} bad lines, {counts['unreadable_files']} unreadable files",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
