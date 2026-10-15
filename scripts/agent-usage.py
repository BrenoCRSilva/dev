#!/usr/bin/env python3
# Read-only usage report for Claude Code and Codex sessions.
#
#   agent-usage.py [--since WHEN] [--until WHEN] [--json]
#                  [--tasks-dir DIR] [--claude-dir DIR] [--codex-dir DIR]
#
# Reads Claude Code logs (<claude-dir>/**/*.jsonl, main sessions and subagents)
# and Codex rollouts (<codex-dir>/**/*.jsonl). Each API response is counted once
# (Claude streams one message as several records with the same message id;
# Codex repeats a response's usage record). Each response is attributed by the
# directory it ran in:
#   <tasks>/<task>              orchestrator
#   <tasks>/<task>/research     researcher (and research/context/<repo> clones)
#   <tasks>/<task>/<folder>     repo agent, named after the folder
#   anywhere else               interactive, named by its directory
#
# Costs are list-price estimates from PRICES, not billing data. A model without a
# price is reported in tokens only (cost n/a). WHEN is YYYY-MM-DD or
# YYYY-MM-DDTHH:MM[:SS], optionally with a zone; a zone-less time is local time.
# --since is inclusive, --until is exclusive. Writes nothing; no network.
import argparse
import collections
import datetime
import functools
import glob
import json
import os
import sys

# USD per million tokens, from the list prices given for this report. None means
# no price was given, so responses from that model cost nothing in the estimate.
# Haiku tiers apply per response, by its prompt tokens (input + cache read +
# cache write): the first tier up to its limit, the last tier above it.
PRICES = {
    "claude-opus-5-5": None,
    "claude-opus-5": None,
    "claude-sonnet-5-5": None,
    "claude-haiku-5-5": [(100_000, 0.10, 0.50), (None, 0.50, 1.50)],
}
# Cache multipliers on the input price: read, 5-minute write, 1-hour write.
CACHE_READ_X = 0.05
CACHE_WRITE_5M_X = 1.25
CACHE_WRITE_1H_X = 2.00

TOKEN_FIELDS = ("input", "output", "cache_read", "cache_write_5m", "cache_write_1h")


def parse_when(text):
    """Aware datetime for a date or date-time; zone-less values are local time."""
    try:
        if len(text) == 10:
            value = datetime.datetime.strptime(text, "%Y-%m-%d")
        else:
            value = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a date or date-time: {text}")
    return value.astimezone() if value.tzinfo is None else value.astimezone(datetime.timezone.utc)


def as_dict(value):
    return value if isinstance(value, dict) else {}


def parse_ts(text):
    if not isinstance(text, str):
        return None
    try:
        value = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return value.astimezone() if value.tzinfo is None else value


def json_lines(path, counts):
    """Parsed JSON objects of a file; unreadable lines are counted, not fatal."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    yield json.loads(line)
                except ValueError:
                    counts["bad_lines"] += 1
    except OSError:
        counts["unreadable_files"] += 1


def claude_responses(claude_dir, counts):
    for path in sorted(glob.glob(os.path.join(claude_dir, "**", "*.jsonl"), recursive=True)):
        for number, record in enumerate(json_lines(path, counts)):
            if not isinstance(record, dict) or record.get("type") != "assistant":
                continue
            message = as_dict(record.get("message"))
            usage = as_dict(message.get("usage"))
            if not usage:
                continue
            split = as_dict(usage.get("cache_creation"))
            write_5m = int(split.get("ephemeral_5m_input_tokens") or 0)
            write_1h = int(split.get("ephemeral_1h_input_tokens") or 0)
            if write_5m + write_1h == 0:
                write_5m = int(usage.get("cache_creation_input_tokens") or 0)
            yield {
                "provider": "claude",
                "key": message.get("id") or f"{path}:{number}",
                "ts": parse_ts(record.get("timestamp")),
                "cwd": record.get("cwd"),
                "session": record.get("sessionId") or path,
                "model": message.get("model") or "unknown",
                "input": int(usage.get("input_tokens") or 0),
                "output": int(usage.get("output_tokens") or 0),
                "cache_read": int(usage.get("cache_read_input_tokens") or 0),
                "cache_write_5m": write_5m,
                "cache_write_1h": write_1h,
            }


def codex_responses(codex_dir, counts):
    for path in sorted(glob.glob(os.path.join(codex_dir, "**", "*.jsonl"), recursive=True)):
        turns = {}
        session_cwd = None
        session_id = path
        usage_records = []
        for record in json_lines(path, counts):
            if not isinstance(record, dict):
                continue
            kind = record.get("type")
            payload = as_dict(record.get("payload"))
            if kind == "session_meta":
                session_cwd = payload.get("cwd") or session_cwd
                session_id = payload.get("session_id") or payload.get("id") or session_id
            elif kind == "turn_context":
                turns[payload.get("turn_id")] = (payload.get("model"), payload.get("cwd"))
            elif kind == "token_usage_record":
                usage_records.append((record.get("timestamp"), payload))
        for stamp, payload in usage_records:
            model, turn_cwd = turns.get(payload.get("turn_id"), (None, None))
            usage = as_dict(payload.get("usage"))
            cached = int(usage.get("cached_input_tokens") or 0)
            # Codex's input_tokens includes the cached part; the cache is priced apart.
            yield {
                "provider": "codex",
                "key": payload.get("response_id") or f"{path}:{stamp}",
                "ts": parse_ts(stamp),
                "cwd": turn_cwd or session_cwd,
                "session": payload.get("session_id") or session_id,
                "model": model or "unknown",
                "input": max(int(usage.get("input_tokens") or 0) - cached, 0),
                "output": int(usage.get("output_tokens") or 0),
                "cache_read": cached,
                "cache_write_5m": int(usage.get("cache_write_input_tokens") or 0),
                "cache_write_1h": 0,
            }


def merge_responses(responses):
    """One entry per API response; streamed copies keep the largest count per field."""
    merged = {}
    for response in responses:
        key = (response["provider"], response["key"])
        if key not in merged:
            merged[key] = dict(response)
            continue
        kept = merged[key]
        for field in TOKEN_FIELDS:
            kept[field] = max(kept[field], response[field])
        if response["ts"] and (kept["ts"] is None or response["ts"] < kept["ts"]):
            kept["ts"] = response["ts"]
    return list(merged.values())


@functools.lru_cache(maxsize=None)
def real_path(path):
    return os.path.realpath(path)


def attribute(cwd, tasks):
    """(task, role, agent) for the directory a response ran in."""
    if not cwd:
        return "-", "unknown", "unknown"
    path = real_path(cwd)
    prefix = tasks + os.sep
    if path.startswith(prefix):
        parts = path[len(prefix):].split(os.sep)
        task, rest = parts[0], parts[1:]
        if not rest:
            return task, "orchestrator", "orchestrator"
        if rest[0] == "research":
            return task, "researcher", "researcher"
        return task, "repo", rest[0]
    return "-", "interactive", path


def request_cost(model, response):
    """USD list-price estimate for one response, or None when the model has no price."""
    tiers = PRICES.get(model)
    if not tiers:
        return None
    prompt = response["input"] + response["cache_read"] + response["cache_write_5m"] + response["cache_write_1h"]
    price_in, price_out = next((p_in, p_out) for limit, p_in, p_out in tiers if limit is None or prompt <= limit)
    cost = (
        response["input"] * price_in
        + response["cache_read"] * price_in * CACHE_READ_X
        + response["cache_write_5m"] * price_in * CACHE_WRITE_5M_X
        + response["cache_write_1h"] * price_in * CACHE_WRITE_1H_X
        + response["output"] * price_out
    )
    return cost / 1_000_000


def new_total():
    total = {"sessions": set(), "turns": 0, "cost": 0.0, "unpriced_turns": 0}
    total.update({field: 0 for field in TOKEN_FIELDS})
    return total


def add_to(total, response, cost):
    total["sessions"].add((response["provider"], response["session"]))
    total["turns"] += 1
    for field in TOKEN_FIELDS:
        total[field] += response[field]
    if cost is None:
        total["unpriced_turns"] += 1
    else:
        total["cost"] += cost


def finish(row, total):
    row["sessions"] = len(total["sessions"])
    row["turns"] = total["turns"]
    for field in TOKEN_FIELDS:
        row[field] = total[field]
    row["cache_write"] = total["cache_write_5m"] + total["cache_write_1h"]
    row["unpriced_turns"] = total["unpriced_turns"]
    row["cost_usd"] = round(total["cost"], 6) if total["unpriced_turns"] < total["turns"] else None
    return row


def build_report(responses, tasks):
    groups = {
        "by_task": collections.defaultdict(new_total),
        "by_agent": collections.defaultdict(new_total),
        "by_model": collections.defaultdict(new_total),
    }
    everything = new_total()
    for response in responses:
        task, role, agent = attribute(response["cwd"], tasks)
        cost = request_cost(response["model"], response)
        add_to(everything, response, cost)
        add_to(groups["by_task"][(task,)], response, cost)
        add_to(groups["by_agent"][(task, role, agent, response["provider"], response["model"])], response, cost)
        add_to(groups["by_model"][(response["provider"], response["model"])], response, cost)

    def rows(name, keys):
        result = []
        for key, total in sorted(groups[name].items()):
            row = dict(zip(keys, key))
            result.append(finish(row, total))
        return result

    return {
        "by_task": rows("by_task", ("task",)),
        "by_agent": rows("by_agent", ("task", "role", "agent", "provider", "model")),
        "by_model": rows("by_model", ("provider", "model")),
        "total": finish({}, everything),
        "pricing": {
            "unit": "USD per million tokens (list-price estimate)",
            "models": {name: tiers for name, tiers in PRICES.items()},
            "cache_read_x": CACHE_READ_X,
            "cache_write_5m_x": CACHE_WRITE_5M_X,
            "cache_write_1h_x": CACHE_WRITE_1H_X,
        },
    }


def money(value):
    return "n/a" if value is None else f"{value:,.4f}"


def print_table(title, headers, rows, out):
    print(title, file=out)
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    numeric = [i for i in range(len(headers)) if headers[i] not in ("task", "role", "agent", "provider", "model")]

    def line(cells):
        parts = []
        for i, cell in enumerate(cells):
            parts.append(cell.rjust(widths[i]) if i in numeric else cell.ljust(widths[i]))
        return "  ".join(parts).rstrip()

    print(line(headers), file=out)
    print("  ".join("-" * w for w in widths), file=out)
    for row in rows:
        print(line(row), file=out)
    print(file=out)


def numbers(row):
    return [
        f"{row['sessions']:,}",
        f"{row['turns']:,}",
        f"{row['input']:,}",
        f"{row['output']:,}",
        f"{row['cache_read']:,}",
        f"{row['cache_write']:,}",
        money(row["cost_usd"]) + ("*" if row["cost_usd"] is not None and row["unpriced_turns"] else ""),
    ]


METRICS = ["sessions", "turns", "input", "output", "cache read", "cache write", "est. USD"]


def print_report(report, meta, out):
    print("Agent usage, list-price estimate (not billing data)", file=out)
    print(f"range: {meta['range']}   files: {meta['files']}   bad lines skipped: {meta['bad_lines']}", file=out)
    print(file=out)
    print_table(
        "Per task",
        ["task"] + METRICS,
        [[r["task"]] + numbers(r) for r in report["by_task"]],
        out,
    )
    print_table(
        "Per agent and model",
        ["task", "role", "agent", "provider", "model"] + METRICS,
        [[r["task"], r["role"], r["agent"], r["provider"], r["model"]] + numbers(r) for r in report["by_agent"]],
        out,
    )
    print_table(
        "Per model",
        ["provider", "model"] + METRICS,
        [[r["provider"], r["model"]] + numbers(r) for r in report["by_model"]],
        out,
    )
    total = report["total"]
    print_table("Total", METRICS, [numbers(total)], out)
    print("n/a: model has no price in PRICES (tokens still counted).", file=out)
    print("*: total includes responses from models without a price; cost covers the priced ones.", file=out)
    print("Haiku tiers by prompt tokens per response; cache read 0.05x, cache write 1.25x (5m) / 2x (1h) of input.", file=out)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read-only Claude Code and Codex usage report.")
    parser.add_argument("--since", type=parse_when, help="include responses at or after this time")
    parser.add_argument("--until", type=parse_when, help="include responses before this time (exclusive)")
    parser.add_argument("--json", action="store_true", help="print JSON instead of tables")
    parser.add_argument("--tasks-dir", default=os.path.expanduser("~/tasks"))
    parser.add_argument("--claude-dir", default=os.path.expanduser("~/.claude/projects"))
    parser.add_argument("--codex-dir", default=os.path.expanduser("~/.codex/sessions"))
    args = parser.parse_args(argv)
    if args.since and args.until and args.since >= args.until:
        parser.error("--since must be before --until")

    counts = collections.Counter()
    files = 0
    for pattern in (os.path.join(args.claude_dir, "**", "*.jsonl"), os.path.join(args.codex_dir, "**", "*.jsonl")):
        files += len(glob.glob(pattern, recursive=True))
    responses = merge_responses(
        list(claude_responses(args.claude_dir, counts)) + list(codex_responses(args.codex_dir, counts))
    )
    kept = []
    for response in responses:
        stamp = response["ts"]
        if (args.since or args.until) and stamp is None:
            continue
        if args.since and stamp < args.since:
            continue
        if args.until and stamp >= args.until:
            continue
        kept.append(response)

    tasks = real_path(args.tasks_dir)
    report = build_report(kept, tasks)
    fmt = "%Y-%m-%d %H:%M %Z"
    meta = {
        "range": " to ".join(
            [args.since.strftime(fmt) if args.since else "start", args.until.strftime(fmt) if args.until else "now"]
        ),
        "files": files,
        "bad_lines": counts["bad_lines"],
        "unreadable_files": counts["unreadable_files"],
        "responses": len(kept),
    }
    if counts["bad_lines"] or counts["unreadable_files"]:
        print(f"warning: skipped {counts['bad_lines']} bad lines, {counts['unreadable_files']} unreadable files",
              file=sys.stderr)
    if args.json:
        report["range"] = {
            "since": args.since.isoformat() if args.since else None,
            "until": args.until.isoformat() if args.until else None,
        }
        report["meta"] = {k: v for k, v in meta.items() if k != "range"}
        json.dump(report, sys.stdout, indent=2, sort_keys=False)
        sys.stdout.write("\n")
    else:
        print_report(report, meta, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
