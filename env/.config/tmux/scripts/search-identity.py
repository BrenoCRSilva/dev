#!/usr/bin/env python3
"""Read-only task/session inventory and typed, revalidated lookup for search."""
import json
import os
from pathlib import Path
import subprocess
import sys


def tmux(*args):
    result = subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=3)
    return result.stdout if result.returncode == 0 else ""


def inventory():
    root = Path(os.environ.get("TASKS_DIR", str(Path.home() / "tasks"))).resolve()
    tasks = sorted(p for p in root.iterdir() if p.is_dir() and not p.is_symlink()) if root.exists() else []
    rows = []
    for path in tasks:
        repos = sorted(p.name for p in path.iterdir() if p.is_dir() and (p / ".git").exists())
        if repos:
            rows.append({"provider": "tasks", "identifier": str(path.resolve()),
                         "text": path.name, "subtext": str(path) + " · " + ", ".join(repos), "actions": ["open"]})
    for line in tmux("list-sessions", "-F", "#{session_id}\t#{session_name}").splitlines():
        token, sep, name = line.partition("\t")
        if sep and token.startswith("$"):
            rows.append({"provider": "sessions", "identifier": token,
                         "text": name, "subtext": "tmux " + token, "actions": ["open"]})
    return rows


def resolve(provider, identifier):
    rows = inventory()
    row = next((r for r in rows if r["provider"] == provider and r["identifier"] == identifier), None)
    if row is None:
        raise ValueError("Selection no longer exists; refresh search")
    if provider == "sessions":
        return identifier
    name = row["text"]
    if not name or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in name):
        raise ValueError("Task name unsupported by task-sessionizer")
    session = name.replace(".", "_").replace(":", "_")
    collisions = [r for r in rows if r["provider"] == "tasks" and r["text"].replace(".", "_").replace(":", "_") == session]
    if len(collisions) != 1:
        raise ValueError("Task names collide after tmux normalization; rename before opening")
    if any(r["provider"] == "sessions" and r["text"] == session for r in rows):
        owner = tmux("show-options", "-qv", "-t", "=" + session, "@pontual_task_root").strip()
        if owner != identifier:
            raise ValueError("Existing tmux session ownership is unverified; use the task popup or rename it")
    return name


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["rows"]:
            print(json.dumps(inventory(), ensure_ascii=False))
        elif len(sys.argv) == 4 and sys.argv[1] == "resolve":
            print(resolve(sys.argv[2], sys.argv[3]))
        else:
            raise ValueError("usage: search-identity.py rows | resolve tasks|sessions identifier")
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
