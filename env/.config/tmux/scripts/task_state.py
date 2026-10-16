"""Runtime state (C6): state.db, the record of what the dispatcher has done. Stdlib only.

Each transition is one BEGIN IMMEDIATE transaction that also writes its events row, so a crash leaves a node
either not started or fully recorded. A report counts only if its mtime is after the attempt's prompt_at.
Only the dispatcher calls these functions. Times are epoch seconds.
"""
import json
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

STATUSES = ("pending", "ready", "running", "done", "stopped", "failed", "cancelled")
EVENT_KINDS = ("reconcile", "install", "start", "settle", "route", "wake", "resolve", "question", "answer")
STATUS_SQL = ", ".join(f"'{status}'" for status in STATUSES)
KIND_SQL = ", ".join(f"'{kind}'" for kind in EVENT_KINDS)
MIGRATIONS = {
    1: [
        f"""CREATE TABLE nodes (
            id TEXT PRIMARY KEY,
            agent TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ({STATUS_SQL})),
            attempt INTEGER NOT NULL DEFAULT 0,
            started_at REAL, ended_at REAL, report TEXT, head_sha TEXT, route TEXT, tier TEXT, reason TEXT,
            plan_hash TEXT)""",
        """CREATE TABLE attempts (
            node TEXT NOT NULL, attempt INTEGER NOT NULL, session_id TEXT, prompt_at REAL, started_at REAL,
            ended_at REAL, report_mtime REAL, budget_turns INTEGER, budget_prompt_k INTEGER,
            PRIMARY KEY (node, attempt))""",
        f"""CREATE TABLE events (
            ts REAL NOT NULL, node TEXT, kind TEXT NOT NULL CHECK (kind IN ({KIND_SQL})), detail TEXT)""",
        """CREATE TABLE wakes (
            id INTEGER PRIMARY KEY, node TEXT NOT NULL, tier TEXT, rule TEXT, reason TEXT, pointers TEXT,
            options TEXT, audit TEXT, created_at REAL NOT NULL, resolved_at REAL, resolution TEXT)""",
        """CREATE TABLE judgements (
            node TEXT, attempt INTEGER, model TEXT, request_hash TEXT, answers_json TEXT, derived_route TEXT,
            mode TEXT, latency_ms INTEGER, cost_usd REAL)""",
        """CREATE TABLE questions (
            qid TEXT PRIMARY KEY, node TEXT, text TEXT, blocking INTEGER, status TEXT, answer_path TEXT)""",
    ],
}


class TransitionError(Exception):
    """A transition is not allowed from the node's current state. Nothing was written."""


def connect(task_root):
    """The task's state.db, in WAL mode and migrated to the current schema. Waits up to 10 s for a lock."""
    conn = sqlite3.connect(Path(task_root) / "state.db", timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    migrate(conn)
    return conn


@contextmanager
def transaction(conn):
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    conn.execute("COMMIT")


def migrate(conn):
    with transaction(conn):
        conn.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        current = conn.execute("SELECT COALESCE(MAX(version), 0) FROM schema_version").fetchone()[0]
        if current > max(MIGRATIONS):
            raise TransitionError(f"state.db schema {current} is newer than this code ({max(MIGRATIONS)})")
        for version in sorted(MIGRATIONS):
            if version > current:
                for statement in MIGRATIONS[version]:
                    conn.execute(statement)
                conn.execute("INSERT INTO schema_version (version) VALUES (?)", (version,))


def report_accepted(report_mtime, prompt_at):
    """A report counts only if it was written after the prompt it answers (C6)."""
    return prompt_at is not None and report_mtime > prompt_at


def snapshot(conn):
    """The node rows by id and the answered q: question ids, as task_plan.ready() reads them."""
    rows = {row["id"]: dict(row) for row in conn.execute("SELECT * FROM nodes")}
    answered = {row["qid"] for row in conn.execute("SELECT qid FROM questions WHERE status = 'answered'")}
    return {"nodes": rows, "answered": answered}


def reconcile(conn, nodes):
    """Brings the nodes table in line with the plan (id -> task_plan.Node). Returns the counts; idempotent.

    New and revived nodes are pending. A pending, ready or finished node takes the plan's agent and hash. A
    running node keeps its agent and gets a wake, since its session is already at work on the old plan.
    A pending or ready node that left the plan is cancelled; a running one raises a wake.
    """
    counts = {"added": 0, "edited": 0, "cancelled": 0, "woken": 0}
    with transaction(conn):
        rows = {row["id"]: row for row in conn.execute("SELECT * FROM nodes")}
        for node_id, node in nodes.items():
            row = rows.get(node_id)
            if row is None:
                conn.execute(
                    "INSERT INTO nodes (id, agent, status, plan_hash) VALUES (?, ?, 'pending', ?)",
                    (node_id, node.agent, node.plan_hash),
                )
                counts["added"] += 1
            elif row["status"] == "cancelled":
                conn.execute(
                    "UPDATE nodes SET agent = ?, status = 'pending', plan_hash = ? WHERE id = ?",
                    (node.agent, node.plan_hash, node_id),
                )
                counts["added"] += 1
            elif row["plan_hash"] != node.plan_hash:
                counts["edited"] += 1
                if row["status"] == "running":
                    counts["woken"] += _wake_once(conn, node_id, "plan-changed", "plan changed while the node runs")
                    conn.execute("UPDATE nodes SET plan_hash = ? WHERE id = ?", (node.plan_hash, node_id))
                else:
                    conn.execute(
                        "UPDATE nodes SET agent = ?, plan_hash = ? WHERE id = ?", (node.agent, node.plan_hash, node_id)
                    )
        for node_id, row in rows.items():
            if node_id in nodes:
                continue
            if row["status"] in ("pending", "ready"):
                conn.execute("UPDATE nodes SET status = 'cancelled' WHERE id = ?", (node_id,))
                counts["cancelled"] += 1
            elif row["status"] == "running":
                counts["woken"] += _wake_once(conn, node_id, "removed-running", "node was removed from the plan while it runs")
        _event(conn, None, "reconcile", json.dumps(counts, sort_keys=True))
    return counts


def install(conn, node_id, budget):
    """pending or ready -> ready, with a new attempt that carries the node's budget. Returns the attempt number."""
    with transaction(conn):
        row = _row(conn, node_id)
        if row["status"] not in ("pending", "ready"):
            raise TransitionError(f"{node_id} is {row['status']}, not installable")
        attempt = row["attempt"] + 1
        conn.execute("UPDATE nodes SET status = 'ready', attempt = ? WHERE id = ?", (attempt, node_id))
        conn.execute(
            "INSERT INTO attempts (node, attempt, budget_turns, budget_prompt_k) VALUES (?, ?, ?, ?)",
            (node_id, attempt, budget["turns"], budget["prompt_k"]),
        )
        _event(conn, node_id, "install", f"attempt {attempt}")
        return attempt


def start(conn, node_id, session_id=None, prompt_at=None):
    """ready -> running. prompt_at is when the prompt goes out (now by default). One running node per agent."""
    now = time.time()
    prompt_at = now if prompt_at is None else prompt_at
    with transaction(conn):
        row = _row(conn, node_id)
        if row["status"] != "ready":
            raise TransitionError(f"{node_id} is {row['status']}, not ready")
        busy = conn.execute("SELECT id FROM nodes WHERE agent = ? AND status = 'running'", (row["agent"],)).fetchone()
        if busy:
            raise TransitionError(f"{row['agent']} is already running {busy['id']}")
        conn.execute("UPDATE nodes SET status = 'running', started_at = ?, ended_at = NULL WHERE id = ?", (now, node_id))
        conn.execute(
            "UPDATE attempts SET session_id = ?, prompt_at = ?, started_at = ? WHERE node = ? AND attempt = ?",
            (session_id, prompt_at, now, node_id, row["attempt"]),
        )
        _event(conn, node_id, "start", f"attempt {row['attempt']}")


def settle(conn, node_id, report, report_mtime, head_sha=None):
    """Records the step's report if it was written after the prompt. Returns whether it was accepted."""
    with transaction(conn):
        row = _row(conn, node_id)
        if row["status"] != "running":
            raise TransitionError(f"{node_id} is {row['status']}, not running")
        attempt = conn.execute(
            "SELECT prompt_at FROM attempts WHERE node = ? AND attempt = ?", (node_id, row["attempt"])
        ).fetchone()
        if not report_accepted(report_mtime, attempt["prompt_at"]):
            _event(conn, node_id, "settle", f"rejected {report}: written before its prompt")
            return False
        conn.execute("UPDATE nodes SET report = ?, head_sha = ?, ended_at = ? WHERE id = ?", (report, head_sha, time.time(), node_id))
        conn.execute(
            "UPDATE attempts SET report_mtime = ?, ended_at = ? WHERE node = ? AND attempt = ?",
            (report_mtime, time.time(), node_id, row["attempt"]),
        )
        _event(conn, node_id, "settle", f"accepted {report}")
        return True


def route(conn, node_id, outcome, reason="", tier=None):
    """running -> done (outcome continue or checkpoint), stopped:<why> or failed:<why>."""
    status = _route_status(outcome)
    with transaction(conn):
        row = _row(conn, node_id)
        if row["status"] != "running":
            raise TransitionError(f"{node_id} is {row['status']}, not running")
        conn.execute(
            "UPDATE nodes SET status = ?, route = ?, reason = ?, tier = ? WHERE id = ?",
            (status, outcome, reason, tier, node_id),
        )
        _event(conn, node_id, "route", f"{outcome}: {reason}" if reason else outcome)


def wake(conn, node_id, tier, rule, reason, pointers=None, options=None, audit=None):
    """Raises a wake for Opus or the user on the node. Returns the wake id."""
    with transaction(conn):
        _row(conn, node_id)
        return _wake(conn, node_id, tier, rule, reason, pointers, options, audit)


def resolve(conn, wake_id, resolution):
    with transaction(conn):
        row = conn.execute("SELECT node, resolved_at FROM wakes WHERE id = ?", (wake_id,)).fetchone()
        if row is None:
            raise TransitionError(f"unknown wake {wake_id}")
        if row["resolved_at"] is not None:
            raise TransitionError(f"wake {wake_id} is already resolved")
        conn.execute("UPDATE wakes SET resolved_at = ?, resolution = ? WHERE id = ?", (time.time(), resolution, wake_id))
        _event(conn, row["node"], "resolve", f"wake {wake_id}: {resolution}")


def _route_status(outcome):
    if outcome in ("continue", "checkpoint"):
        return "done"
    kind, _, why = outcome.partition(":")
    if kind in ("stopped", "failed") and why:
        return kind
    raise TransitionError(f"unknown route {outcome!r}")


def _row(conn, node_id):
    row = conn.execute("SELECT * FROM nodes WHERE id = ?", (node_id,)).fetchone()
    if row is None:
        raise TransitionError(f"unknown node {node_id}")
    return row


def _event(conn, node_id, kind, detail):
    conn.execute("INSERT INTO events (ts, node, kind, detail) VALUES (?, ?, ?, ?)", (time.time(), node_id, kind, detail))


def _wake(conn, node_id, tier, rule, reason, pointers=None, options=None, audit=None):
    def as_json(value):
        return None if value is None else json.dumps(value)

    cursor = conn.execute(
        "INSERT INTO wakes (node, tier, rule, reason, pointers, options, audit, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (node_id, tier, rule, reason, as_json(pointers), as_json(options), as_json(audit), time.time()),
    )
    _event(conn, node_id, "wake", f"{rule}: {reason}")
    return cursor.lastrowid


def _wake_once(conn, node_id, rule, reason):
    """Raises the wake unless one with this rule is still open for the node. Returns 1 when it raised one."""
    open_wake = conn.execute(
        "SELECT 1 FROM wakes WHERE node = ? AND rule = ? AND resolved_at IS NULL", (node_id, rule)
    ).fetchone()
    if open_wake:
        return 0
    _wake(conn, node_id, "opus", rule, reason)
    return 1
