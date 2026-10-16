#!/usr/bin/env python3
"""Spend per role for the task agents (contract C1), from Claude Code and Codex transcripts.

    task-spend.py [--since WHEN] [--until WHEN] [--by day|task] [--json]
                  [--split WHEN] [--prices FILE]
                  [--claude-dir DIR] [--codex-dir DIR] [--tasks-dir DIR]

Reads <claude-dir>/**/*.jsonl (subagent sidechains included) and <codex-dir>/**/*.jsonl
when present. Read-only: writes nothing, no network. Each API response counts once:
Claude streams one message as several records with the same message id, and the
largest count seen for each field is kept.

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
"""
import argparse
import collections
import datetime
import functools
import glob
import json
import os
import sys

# USD per million tokens. Cache read is 0.05x input; cache write is 1.25x (5m) or 2x (1h),
# as the Anthropic pricing page states. A model's tiers are picked by its response's prompt
# size (input + cache tokens): the first tier whose upto holds it; the last tier has upto null.
# Known ids' prices are copied from scripts/agent-usage.py (retrieved 2026-10-15); verify.
# TODO: claude-opus-5 has no price. Codex models (gpt-6-*) have none either: unpriced until
# added here or passed with --prices.
PRICES = {
    "claude-opus-5-5": [
        {"upto": None, "input": 4.00, "output": 20.00, "cache_read": 0.20,
         "cache_write_5m": 5.00, "cache_write_1h": 8.00},
    ],
    "claude-sonnet-5-5": [
        {"upto": None, "input": 2.00, "output": 10.00, "cache_read": 0.10,
         "cache_write_5m": 2.50, "cache_write_1h": 4.00},
    ],
    "claude-haiku-5-5": [
        {"upto": 100_000, "input": 0.10, "output": 0.50, "cache_read": 0.005,
         "cache_write_5m": 0.125, "cache_write_1h": 0.20},
        {"upto": None, "input": 0.50, "output": 2.50, "cache_read": 0.025,
         "cache_write_5m": 0.625, "cache_write_1h": 1.00},
    ],
    "claude-opus-5": None,
}
TOKEN_FIELDS = ("input", "output", "cache_read", "cache_write_5m", "cache_write_1h")
TEXT_COLUMNS = ("date", "task", "role", "model")


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
            if not write_5m and not write_1h:
                write_5m = num(usage.get("cache_creation_input_tokens"))
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
            }


def codex_responses(root, counts):
    for path in sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)):
        turns, usage_records = {}, []
        cwd, session = None, None
        for record in read_lines(path, counts):
            if not isinstance(record, dict):
                continue
            payload = as_dict(record.get("payload"))
            kind = record.get("type")
            if kind == "session_meta":
                cwd = payload.get("cwd") or cwd
                session = payload.get("session_id") or payload.get("id") or session
            elif kind == "turn_context":
                turns[payload.get("turn_id")] = (payload.get("model"), payload.get("cwd"))
            elif kind == "token_usage_record":
                usage_records.append((record.get("timestamp"), payload))
        for stamp, payload in usage_records:
            model, turn_cwd = turns.get(payload.get("turn_id"), (None, None))
            usage = as_dict(payload.get("usage"))
            cached = num(usage.get("cached_input_tokens"))
            # Codex's input_tokens includes the cached part; the cache is priced apart.
            yield {
                "provider": "codex",
                "key": payload.get("response_id") or f"{path}:{stamp}",
                "ts": parse_ts(stamp),
                "cwd": turn_cwd or cwd,
                "session": payload.get("session_id") or session or path,
                "model": model or "unknown",
                "sidechain": False,
                "input": max(num(usage.get("input_tokens")) - cached, 0),
                "output": num(usage.get("output_tokens")),
                "cache_read": cached,
                "cache_write_5m": num(usage.get("cache_write_input_tokens")),
                "cache_write_1h": 0,
            }


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


def cost_of(response, prices):
    """USD for one response at its price tier, or None when its model has no price."""
    prompt = response["input"] + response["cache_read"] + response["cache_write_5m"] + response["cache_write_1h"]
    for tier in prices.get(response["model"]) or ():
        if tier["upto"] is None or prompt <= tier["upto"]:
            return sum(response[field] * tier[field] for field in TOKEN_FIELDS) / 1_000_000
    return None


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


def fmt(value):
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:,.4f}"
    if isinstance(value, int):
        return f"{value:,}"
    return str(value)


def print_table(columns, rows, out):
    """columns: (header, key) pairs. Text columns are left-aligned, numbers right-aligned."""
    cells = [[header for header, _ in columns]]
    cells += [[fmt(row.get(key)) for _, key in columns] for row in rows]
    widths = [max(len(line[i]) for line in cells) for i in range(len(columns))]
    for line in cells:
        justified = [
            cell.ljust(width) if key in TEXT_COLUMNS else cell.rjust(width)
            for (_, key), cell, width in zip(columns, line, widths)
        ]
        print("  ".join(justified).rstrip(), file=out)


ROW_COLUMNS = [
    ("date", "date"), ("task", "task"), ("role", "role"), ("model", "model"), ("sessions", "sessions"),
    ("input", "input_tokens"), ("output", "output_tokens"), ("cache read", "cache_read_tokens"),
    ("cache write", "cache_write_tokens"), ("USD", "cost_usd"), ("unpriced", "unpriced_turns"),
]
SPLIT_COLUMNS = [("role", "role")] + [
    (f"{period} {name}", f"{period}_{key}")
    for period in ("before", "after")
    for name, key in (("days", "days"), ("sessions", "sessions"), ("USD/day", "usd_per_day"),
                      ("USD/session", "usd_per_session"))
]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Spend per role for the task agents (contract C1).")
    parser.add_argument("--since", type=parse_when, help="responses at or after this time")
    parser.add_argument("--until", type=parse_when, help="responses before this time (exclusive)")
    parser.add_argument("--by", choices=["day", "task"], default="day",
                        help="rows per day, or per task over all days (date is then '-')")
    parser.add_argument("--split", type=parse_when, metavar="WHEN",
                        help="per-role averages before and after WHEN (text only)")
    parser.add_argument("--json", action="store_true", help="print the rows as a JSON list")
    parser.add_argument("--prices", metavar="FILE", help="JSON object of model -> tiers (or null), overriding PRICES")
    parser.add_argument("--claude-dir", default=os.path.expanduser("~/.claude/projects"))
    parser.add_argument("--codex-dir", default=os.path.expanduser("~/.codex/sessions"))
    parser.add_argument("--tasks-dir", default=os.path.expanduser("~/tasks"))
    args = parser.parse_args(argv)
    if args.since and args.until and args.since >= args.until:
        parser.error("--since must be before --until")
    if args.split and args.json:
        parser.error("--split prints text only")
    try:
        prices = load_prices(args.prices) if args.prices else PRICES
    except (OSError, ValueError) as error:
        parser.error(f"--prices: {error}")

    counts = collections.Counter()
    merged = merge_responses(
        list(claude_responses(args.claude_dir, counts)) + list(codex_responses(args.codex_dir, counts))
    )
    tasks = real_path(args.tasks_dir)
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
        response["task"], response["role"] = attribute(response["cwd"], response["sidechain"], tasks)
        response["cost"] = cost_of(response, prices)
        responses.append(response)

    if args.split:
        timed = [response for response in responses if response["ts"] is not None]
        print(f"split at {args.split.isoformat()}: before is earlier, after is from that time")
        print_table(SPLIT_COLUMNS, split_rows(timed, args.split), sys.stdout)
    elif args.json:
        json.dump(rows_by(responses, args.by), sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        rows = rows_by(responses, args.by)
        print_table(ROW_COLUMNS, rows + [{"date": "total", "task": "", "role": "", "model": "", **fold(responses)}],
                    sys.stdout)

    unpriced = sorted({response["model"] for response in responses if response["cost"] is None})
    if unpriced:
        print(f"unpriced models (tokens counted, cost left out): {', '.join(unpriced)}", file=sys.stderr)
    if counts["bad_lines"] or counts["unreadable_files"]:
        print(f"warning: skipped {counts['bad_lines']} bad lines, {counts['unreadable_files']} unreadable files",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
