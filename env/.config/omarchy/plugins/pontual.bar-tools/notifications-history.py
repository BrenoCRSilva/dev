#!/usr/bin/env python3
"""Read the native Omarchy notification archive for the bar history popup.

Archived notifications no longer have live notification objects to invoke.
The only writes are a validated per-row removal and a validated full archive
clear, both invoked only by explicit controls in the user's history popup.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any


def read_history(directory: Path, limit: int = 10) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        with os.scandir(directory) as entries:
            files = [entry for entry in entries if entry.name.endswith(".json") and entry.is_file(follow_symlinks=False)]
    except OSError:
        return rows

    for file_entry in files:
        try:
            with open(file_entry.path, "r", encoding="utf-8") as source:
                value = json.load(source)
        except (OSError, UnicodeError, json.JSONDecodeError):
            continue
        if not isinstance(value, dict):
            continue

        raw_timestamp = value.get("timestamp", 0)
        try:
            timestamp = int(raw_timestamp)
        except (TypeError, ValueError, OverflowError):
            continue
        if timestamp <= 0:
            continue

        # Match NotificationLogic.historyEntry's on-disk fields but omit
        # execArgv: it is expired with the original notification object.
        rows.append({
            "key": file_entry.name,
            "app": _string(value.get("app")),
            "appIcon": _string(value.get("appIcon")),
            "summary": _string(value.get("summary")),
            "body": _string(value.get("body")),
            "image": _string(value.get("image")),
            "glyph": _string(value.get("glyph")),
            "urgency": _urgency(value.get("urgency")),
            "timestamp": timestamp,
            "actionsAvailable": False,
        })

    rows.sort(key=lambda row: (row["timestamp"], row["key"]), reverse=True)
    return rows[: max(0, int(limit))]


def remove_history_entry(directory: Path, key: str) -> bool:
    """Remove one native archive record after strict path/type validation."""
    if not re.fullmatch(r"[0-9]+-[0-9]+\.json", key):
        return False
    try:
        if directory.is_symlink():
            return False
        root = directory.resolve(strict=True)
        target = directory / key
        if target.parent.resolve(strict=True) != root:
            return False
        metadata = target.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            return False
        target.unlink()
        image_dir = directory.parent / "images"
        if image_dir.is_dir() and not image_dir.is_symlink():
            stem = key[:-5]
            for image in image_dir.iterdir():
                if image.name.startswith(stem + "-") and not image.is_symlink() and image.is_file():
                    image.unlink(missing_ok=True)
        return True
    except OSError:
        return False


def clear_history(directory: Path) -> int:
    """Clear regular native archive records only after an explicit UI action."""
    if directory.is_symlink():
        return 0
    try:
        root = directory.resolve(strict=True)
        if not root.is_dir():
            return 0
        with os.scandir(root) as entries:
            keys = [entry.name for entry in entries
                    if re.fullmatch(r"[0-9]+-[0-9]+\.json", entry.name)
                    and entry.is_file(follow_symlinks=False)]
        return sum(remove_history_entry(root, key) for key in keys)
    except OSError:
        return 0


def _string(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _urgency(value: Any) -> int:
    try:
        urgency = int(value)
    except (TypeError, ValueError, OverflowError):
        return 1
    return urgency if urgency in (0, 1, 2) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--limit", type=int, default=10, help=argparse.SUPPRESS)
    parser.add_argument("--remove", help=argparse.SUPPRESS)
    parser.add_argument("--clear", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    history_dir = args.directory or Path.home() / ".local/state/omarchy/notifications/history"
    try:
        if args.remove is not None:
            json.dump({"removed": remove_history_entry(history_dir, args.remove)}, sys.stdout)
            sys.stdout.write("\n")
            return 0
        if args.clear:
            json.dump({"cleared": True, "removed": clear_history(history_dir)}, sys.stdout)
            sys.stdout.write("\n")
            return 0
        json.dump(read_history(history_dir, args.limit), sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    except (OSError, ValueError):
        # Never log notification data or filesystem details into the shell log.
        sys.stdout.write("[]\n")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
