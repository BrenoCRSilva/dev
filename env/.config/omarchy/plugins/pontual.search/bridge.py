#!/usr/bin/env python3
"""Bounded JSON-lines UI adapter for Elephant v2.22.1 framed JSON.

Persistent UI process, isolated per-query sockets: closing a stale socket avoids
ambiguous upstream async qids. No shell parsing, subscriptions or daemon startup.
Python stdlib deliberately avoids another compiler/plugin ABI dependency.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import struct
import sys

MAX_FRAME = 1024 * 1024
MAX_LINE = 65536
TIMEOUT = 5
REMOTE = {"desktopapplications", "files", "calc", "clipboard", "websearch"}
LOCAL = {"tasks", "sessions", "commands", "themes"}
SAFE_ACTIONS = {"desktopapplications": {"start"}, "files": {"open"},
                "calc": {"copy"}, "clipboard": {"copy"},
                "websearch": {"search", "open_url"}}
COMMANDS = {
    "native-menu": ("Native Omarchy menu", ["omarchy", "menu"]),
    "terminal": ("Open terminal", ["omarchy", "launch", "terminal"]),
    "browser": ("Open browser", ["omarchy", "launch", "browser"]),
}
MOCK = [
    {"provider": "desktopapplications", "identifier": "fixture:ghostty", "text": "Ghostty", "subtext": "Offline fixture", "icon": "utilities-terminal", "actions": ["start"]},
    {"provider": "files", "identifier": "fixture:file", "text": "São Paulo notes.txt", "subtext": "Fixture filename", "actions": ["open"]},
    {"provider": "tasks", "identifier": "fixture:task", "text": "omarchy-syn", "subtext": "Fixture task", "actions": ["open"]},
    {"provider": "sessions", "identifier": "fixture:session", "text": "omarchy_syn", "subtext": "Distinct fixture session", "actions": ["open"]},
    {"provider": "calc", "identifier": "fixture:calc", "text": "4", "subtext": "2 + 2 (fixture)", "actions": ["copy"]},
]


def encode_request(kind, payload):
    body = json.dumps(payload, ensure_ascii=False).encode()
    if len(body) > MAX_FRAME:
        raise ValueError("request frame too large")
    return bytes((kind, 1)) + struct.pack(">I", len(body)) + body


async def read_frame(reader):
    header = await reader.readexactly(5)
    kind, size = header[0], struct.unpack(">I", header[1:])[0]
    if size > MAX_FRAME:
        raise ValueError("response frame too large")
    body = await reader.readexactly(size)
    if kind in (253, 254, 255):
        if body:
            raise ValueError("status frame has unexpected payload")
        return kind, None
    if kind == 2 and not body:
        return kind, None
    return kind, json.loads(body)


def normalize_item(item):
    if not isinstance(item, dict):
        raise ValueError("invalid item")
    for key in ("provider", "identifier", "text"):
        if not isinstance(item.get(key), str) or not item[key] or len(item[key]) > 8192:
            raise ValueError("invalid item " + key)
    actions = item.get("actions", [])
    if not isinstance(actions, list) or len(actions) > 100 or any(not isinstance(x, str) or len(x) > 256 for x in actions):
        raise ValueError("invalid actions")
    return {key: item[key] for key in ("provider", "identifier", "text", "subtext", "icon", "score", "actions", "state") if key in item}


class Bridge:
    def __init__(self, socket_path=None, adapter=None, mock=False, emit=None):
        self.socket_path = socket_path or str(Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "elephant/elephant.sock")
        self.adapter = adapter or str(Path.home() / ".config/tmux/scripts/task-sessionizer.sh")
        self.mock = mock
        self.emit = emit or self.print_frame
        self.current = None
        self.query_task = None
        self.known = {}
        self.query_text = ""

    @staticmethod
    def print_frame(frame):
        print(json.dumps(frame, ensure_ascii=False), flush=True)

    def send(self, kind, rid, **values):
        self.emit({"type": kind, "requestId": rid, **values})

    async def command(self, *argv):
        proc = await asyncio.create_subprocess_exec(*argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        async def bounded_read(stream):
            data = bytearray()
            while chunk := await stream.read(8192):
                data.extend(chunk)
                if len(data) > MAX_FRAME:
                    raise ValueError("adapter output too large")
            return bytes(data)
        try:
            out, err, _ = await asyncio.wait_for(asyncio.gather(bounded_read(proc.stdout), bounded_read(proc.stderr), proc.wait()), TIMEOUT)
            if proc.returncode:
                raise ValueError("adapter failed: " + err.decode(errors="replace")[:300])
            return out
        finally:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()

    async def local_rows(self, providers):
        rows = []
        if providers & {"tasks", "sessions"}:
            entries = json.loads(await self.command(self.adapter, "search-rows"))
            if not isinstance(entries, list) or len(entries) > 10000:
                raise ValueError("invalid task inventory")
            rows.extend(normalize_item(x) for x in entries if x.get("provider") in providers & {"tasks", "sessions"})
        if "commands" in providers:
            rows.extend({"provider": "commands", "identifier": key, "text": title, "actions": ["open"]} for key, (title, _) in COMMANDS.items())
        if "themes" in providers:
            for root in (Path("/usr/share/omarchy/themes"), Path.home() / ".config/omarchy/themes"):
                if root.is_dir():
                    rows.extend({"provider": "themes", "identifier": p.name, "text": p.name, "actions": ["apply"]} for p in sorted(root.iterdir()) if p.is_dir() and not p.name.startswith("-"))
        return rows

    async def connect(self):
        # One bounded retry; future queries retry naturally after daemon recovery.
        for attempt in range(2):
            try:
                return await asyncio.wait_for(asyncio.open_unix_connection(self.socket_path), 1)
            except (OSError, asyncio.TimeoutError):
                if attempt:
                    raise
                await asyncio.sleep(0.1)

    async def remote_rows(self, provider, query, limit):
        writer = None
        rows = {}
        try:
            async with asyncio.timeout(TIMEOUT):
                reader, writer = await self.connect()
                writer.write(encode_request(0, {"providers": [provider], "query": query, "maxresults": limit, "exactsearch": False}))
                await writer.drain()
                for _ in range(1000):
                    kind, value = await read_frame(reader)
                    if kind == 255:
                        return list(rows.values())
                    if kind == 254:
                        continue
                    if kind not in (0, 1) or not isinstance(value, dict):
                        raise ValueError("unexpected query response")
                    item = normalize_item(value.get("item"))
                    if item["provider"] != provider:
                        raise ValueError("unexpected result provider")
                    item["actions"] = [a for a in item.get("actions", []) if a in SAFE_ACTIONS[provider]]
                    if item["identifier"] in rows or len(rows) < limit:
                        rows[item["identifier"]] = item
                raise ValueError("too many response frames")
        finally:
            if writer:
                writer.close()
                await writer.wait_closed()

    async def query(self, rid, query, providers, limit):
        # Publish each source as soon as ready, reserving a fair initial quota
        # for other sources. Fill unused reservations after all sources finish.
        # UI arrival order can vary; provider+identifier identity never changes.
        providers = list(dict.fromkeys(providers))
        quotas = {p: limit // len(providers) + (i < limit % len(providers)) for i, p in enumerate(providers)}
        count = 0
        def publish(item):
            nonlocal count
            if self.current != rid or count >= limit:
                return
            key = (item["provider"], item["identifier"])
            if key in self.known:
                return
            self.known[key] = item
            self.send("item", rid, item=item)
            count += 1
        async def source(provider):
            try:
                if self.mock:
                    rows = [x for x in MOCK if x["provider"] == provider]
                elif provider in REMOTE:
                    rows = await self.remote_rows(provider, query, limit)
                else:
                    rows = await self.local_rows({provider})
                if self.mock or provider in LOCAL:
                    rows = [normalize_item(x) for x in rows if query.casefold() in (x["text"] + " " + x.get("subtext", "")).casefold() or (self.mock and provider == "calc" and query == "2 + 2")]
                    rows = sorted(rows, key=lambda x: (x["text"].casefold(), x["identifier"]))[:limit]
                for item in rows[:quotas[provider]]:
                    publish(item)
                return rows
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                if self.current == rid:
                    self.send("error", rid, provider=provider, message=str(exc)[:400])
                return []
        buckets = await asyncio.gather(*(source(p) for p in providers))
        if self.current != rid:
            return
        for index in range(limit):
            for rows in buckets:
                if index < len(rows):
                    publish(rows[index])
        self.send("done", rid, count=count, empty=count == 0)

    async def activate(self, req):
        rid = req.get("requestId")
        key = (req.get("provider"), req.get("identifier"))
        item = self.known.get(key) if rid == self.current else None
        action = req.get("action")
        if not item or not isinstance(action, str) or action not in item.get("actions", []) or key[0] in REMOTE and action not in SAFE_ACTIONS[key[0]]:
            raise ValueError("stale/unknown result or unsupported action")
        if self.mock:
            self.send("activated", rid, mock=True, provider=key[0], identifier=key[1])
            return
        if key[0] in ("tasks", "sessions"):
            await self.command(self.adapter, "search-open", key[0], key[1])
        elif key[0] == "commands":
            # A terminal launcher may remain attached for the terminal lifetime.
            # Do not kill it at a search timeout or hold the query loop open.
            proc = await asyncio.create_subprocess_exec(*COMMANDS[key[1]][1], stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL, start_new_session=True)
            asyncio.create_task(proc.wait())
        elif key[0] == "themes":
            rows = await self.local_rows({"themes"})
            if not any(row["identifier"] == key[1] for row in rows):
                raise ValueError("theme no longer exists")
            await self.command("omarchy", "theme", "set", key[1])
        else:
            writer = None
            try:
                async with asyncio.timeout(TIMEOUT):
                    reader, writer = await self.connect()
                    writer.write(encode_request(1, {"provider": key[0], "identifier": key[1], "action": action, "query": self.query_text, "arguments": "", "single": True}))
                    await writer.drain()
                    kind, _ = await read_frame(reader)
                    if kind != 2:
                        raise ValueError("unexpected activation response")
            finally:
                if writer:
                    writer.close()
                    await writer.wait_closed()
        self.send("activated", rid, provider=key[0], identifier=key[1], acknowledgement="provider returned; application success not guaranteed")

    async def handle(self, req):
        rid = req.get("requestId")
        try:
            if type(rid) not in (int, str) or isinstance(rid, str) and len(rid) > 128:
                raise ValueError("invalid requestId")
            op = req.get("op")
            if op == "query":
                query = req.get("query", "")
                providers = req.get("providers", ["desktopapplications", "tasks", "sessions", "commands"])
                limit = req.get("limit", 30)
                if not isinstance(query, str) or len(query) > 4096 or not isinstance(providers, list) or not providers or len(providers) > 10 or any(not isinstance(p, str) or p not in REMOTE | LOCAL for p in providers) or type(limit) is not int or not 1 <= limit <= 100:
                    raise ValueError("invalid query/providers/limit")
                if self.query_task:
                    self.query_task.cancel()
                    await asyncio.gather(self.query_task, return_exceptions=True)
                self.current, self.query_text, self.known = rid, query, {}
                self.send("reset", rid)
                self.query_task = asyncio.create_task(self.query(rid, query, providers, limit))
            elif op == "cancel":
                if rid == self.current:
                    self.current, self.known = None, {}
                    if self.query_task:
                        self.query_task.cancel()
                        await asyncio.gather(self.query_task, return_exceptions=True)
                    self.send("done", rid, cancelled=True)
            elif op == "activate":
                await self.activate(req)
            else:
                raise ValueError("unknown operation")
        except Exception as exc:
            self.send("error", rid, message=str(exc)[:400])


async def main(args):
    bridge = Bridge(args.socket, args.adapter, args.mock)
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.buffer.readline, MAX_LINE + 1)
            if not line:
                break
            if len(line) > MAX_LINE or not line.endswith(b"\n"):
                bridge.send("error", None, message="oversized or unterminated JSON line; closing input")
                break
            try:
                req = json.loads(line)
                if not isinstance(req, dict):
                    raise ValueError("request must be an object")
                await bridge.handle(req)
            except (ValueError, UnicodeError) as exc:
                bridge.send("error", None, message=str(exc)[:400])
    finally:
        if bridge.query_task:
            bridge.query_task.cancel()
            await asyncio.gather(bridge.query_task, return_exceptions=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mock", action="store_true", help="offline fixtures; activation emits acknowledgement only")
    parser.add_argument("--socket")
    parser.add_argument("--adapter")
    asyncio.run(main(parser.parse_args()))
