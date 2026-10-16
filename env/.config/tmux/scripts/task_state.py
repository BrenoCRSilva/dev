"""Runtime state (C6): state.db, the record of what the dispatcher has done. Stdlib only.

Each transition is one BEGIN IMMEDIATE transaction that also writes its events row, so a crash leaves a node
either not started or fully recorded. A report counts only if its mtime is after the attempt's prompt_at.
Only the dispatcher calls these functions. Times are epoch seconds.
"""
import json
import sqlite3
import time
import warnings
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
    2: [
        """CREATE TABLE pauses (target TEXT PRIMARY KEY, created_at REAL NOT NULL)""",
    ],
    3: [
        """CREATE TABLE plan_state (id INTEGER PRIMARY KEY CHECK (id = 1), error TEXT)""",
    ],
    4: [
        # JSON list; NULL for attempts started before this migration.
        """ALTER TABLE attempts ADD COLUMN scope TEXT""",
    ],
    5: [
        # jev judgements (T1): the input tokens, the error when jev failed, when it was judged, and the final outcome
        # the calibration reads (continue, stopped:<why>, failed:<why>, or resolved:<resolution>).
        """ALTER TABLE judgements ADD COLUMN input_tokens INTEGER""",
        """ALTER TABLE judgements ADD COLUMN error TEXT""",
        """ALTER TABLE judgements ADD COLUMN judged_at REAL""",
        """ALTER TABLE judgements ADD COLUMN outcome TEXT""",
        """ALTER TABLE judgements ADD COLUMN outcome_at REAL""",
    ],
}
PLAN_RULE = "plan-invalid"


class TransitionError(Exception):
    """A transition is not allowed from the node's current state. Nothing was written."""


def connect(task_root):
    """The task's state.db, in WAL mode and migrated to the current schema. Waits up to 10 s for a lock."""
    conn = sqlite3.connect(Path(task_root) / "state.db", timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    # The journal-mode change can return "locked" at once on a new file, so it is retried (the busy timeout does not cover it).
    for attempt in range(50):
        try:
            mode = conn.execute("PRAGMA journal_mode=WAL").fetchone()[0]
            break
        except sqlite3.OperationalError as error:
            if "locked" not in str(error) or attempt == 49:
                raise
            time.sleep(0.1)
    if mode != "wal":
        warnings.warn(f"state.db journal mode is {mode}, not wal: readers and writers may block each other", RuntimeWarning, stacklevel=2)
    migrate(conn)
    return conn


@contextmanager
def transaction(conn):
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.execute("COMMIT")
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def migrate(conn):
    """Applies the missing migrations. Takes the write lock only when one is missing, so readers never wait on it."""
    if _version(conn) == max(MIGRATIONS):
        return
    with transaction(conn):
        conn.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        current = _version(conn)
        if current > max(MIGRATIONS):
            raise TransitionError(f"state.db schema {current} is newer than this code ({max(MIGRATIONS)})")
        for version in sorted(MIGRATIONS):
            if version > current:
                for statement in MIGRATIONS[version]:
                    conn.execute(statement)
                conn.execute("INSERT INTO schema_version (version) VALUES (?)", (version,))


def _version(conn):
    """The schema version, 0 before the first migration. Reads without the write lock."""
    if conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_version'").fetchone() is None:
        return 0
    return conn.execute("SELECT COALESCE(MAX(version), 0) FROM schema_version").fetchone()[0]


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

    New and revived nodes are pending. A running node keeps its agent and gets a wake that records any agent
    change; the new agent applies at the first reconcile after the node stops. An edited node that is not
    running takes the plan's agent and hash, a ready one goes back to pending (to be installed again), and
    every such edit is logged. A pending or ready node that left the plan is cancelled; a running one raises
    a wake, once per attempt.
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
            elif row["status"] == "cancelled" and (row["route"] != "cancelled" or row["plan_hash"] != node.plan_hash):
                conn.execute(
                    "UPDATE nodes SET agent = ?, status = 'pending', plan_hash = ?, route = NULL WHERE id = ?",
                    (node.agent, node.plan_hash, node_id),
                )
                counts["added"] += 1
            elif row["status"] == "running":
                if row["plan_hash"] != node.plan_hash:
                    counts["edited"] += 1
                    detail = "plan changed while the node runs"
                    if row["agent"] != node.agent:
                        detail += f"; agent {row['agent']} -> {node.agent} applies when it stops"
                    counts["woken"] += _wake_once(conn, node_id, "plan-changed", detail)
                    conn.execute("UPDATE nodes SET plan_hash = ? WHERE id = ?", (node.plan_hash, node_id))
            elif row["plan_hash"] != node.plan_hash or row["agent"] != node.agent:
                status = "pending" if row["status"] == "ready" else row["status"]
                if row["plan_hash"] != node.plan_hash:
                    counts["edited"] += 1
                conn.execute(
                    "UPDATE nodes SET agent = ?, status = ?, plan_hash = ? WHERE id = ?",
                    (node.agent, status, node.plan_hash, node_id),
                )
                reset = f", reset to {status}" if status != row["status"] else ""
                _event(conn, node_id, "reconcile", f"edited while {row['status']}: agent {row['agent']} -> {node.agent}{reset}")
        for node_id, row in rows.items():
            if node_id in nodes:
                continue
            if row["status"] in ("pending", "ready"):
                conn.execute("UPDATE nodes SET status = 'cancelled' WHERE id = ?", (node_id,))
                counts["cancelled"] += 1
            elif row["status"] == "running":
                counts["woken"] += _wake_once(
                    conn, node_id, "removed-running", "node was removed from the plan while it runs", this_attempt=True
                )
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


def start(conn, node_id, session_id=None, prompt_at=None, scope=None):
    """ready -> running. prompt_at is when the prompt goes out (now by default); scope is the attempt's Scope list, kept
    so a restarted dispatcher checks the attempt against what it was started with. One running node per agent."""
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
            "UPDATE attempts SET session_id = ?, prompt_at = ?, started_at = ?, scope = ? WHERE node = ? AND attempt = ?",
            (session_id, prompt_at, now, None if scope is None else json.dumps(scope), node_id, row["attempt"]),
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
        if status == "done" and row["report"] is None:
            raise TransitionError(f"{node_id} has no accepted report, so it cannot route {outcome}")
        conn.execute(
            "UPDATE nodes SET status = ?, route = ?, reason = ?, tier = ? WHERE id = ?",
            (status, outcome, reason, tier, node_id),
        )
        _mark_outcome(conn, node_id, outcome)
        _event(conn, node_id, "route", f"{outcome}: {reason}" if reason else outcome)


def record_judgement(conn, node_id, attempt, judged):
    """One judgements row for a judged attempt (T1): the answers and derived route, or the error when jev failed."""
    with transaction(conn):
        conn.execute(
            "INSERT INTO judgements (node, attempt, model, request_hash, answers_json, derived_route, mode, latency_ms, "
            "cost_usd, input_tokens, error, judged_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (node_id, attempt, judged["model"], judged["request_hash"],
             None if judged["answers"] is None else json.dumps(judged["answers"]), judged["derived_route"], judged["mode"],
             judged["latency_ms"], judged["cost_usd"], judged["input_tokens"], judged["error"], time.time()),
        )


def _mark_outcome(conn, node_id, outcome):
    """Sets the outcome of the node's current attempt, if jev judged it (calibration reads these)."""
    conn.execute(
        "UPDATE judgements SET outcome = ?, outcome_at = ? WHERE node = ? AND attempt = (SELECT attempt FROM nodes WHERE id = ?)",
        (outcome, time.time(), node_id, node_id),
    )


def wake(conn, node_id, tier, rule, reason, pointers=None, options=None, audit=None):
    """Raises a wake for Opus or the user on the node. Returns the wake id. A rule of 'checkpoint' marks a checkpoint."""
    with transaction(conn):
        _row(conn, node_id)
        return _wake(conn, node_id, tier, rule, reason, pointers, options, audit)


RESOLUTIONS = ("continue", "retry", "skip", "cancel", "ack")
# Wakes that report a change and need no node transition: only ack closes them.
INFO_RULES = ("plan-changed", "removed-running", PLAN_RULE, "review")


def resolve(conn, wake_id, resolution, release=False, note=""):
    """Closes the wake and applies the resolution to its node. Refused with TransitionError, and nothing written, when it cannot apply.

    continue: a checkpoint passes (done, route continue); a stopped or failed node whose report was accepted is
    accepted (done, route continue).
    retry: a stopped or failed node goes back to pending, so its next install is a new attempt; route, report,
    head_sha and ended_at are cleared.
    skip: the node is done with route skipped, so its successors stay blocked. With release, route is continue,
    so they start (the node has no report).
    cancel: the node is cancelled with route cancelled. reconcile keeps it cancelled until its plan entry changes.
    retry, skip and cancel also close the node's other open wakes, except checkpoints.
    ack: closes the wake and changes no node. It is the only resolution for an informational wake (INFO_RULES) or
    one with no node.
    """
    if resolution not in RESOLUTIONS:
        raise TransitionError(f"unknown resolution {resolution!r}")
    with transaction(conn):
        row = conn.execute("SELECT node, rule, resolved_at FROM wakes WHERE id = ?", (wake_id,)).fetchone()
        if row is None:
            raise TransitionError(f"unknown wake {wake_id}")
        if row["resolved_at"] is not None:
            raise TransitionError(f"wake {wake_id} is already resolved")
        detail = f"wake {wake_id}: {resolution}" + (" (release)" if release else "") + (f": {note}" if note else "")
        if resolution != "ack":
            if not row["node"] or row["rule"] in INFO_RULES:
                raise TransitionError(f"wake {wake_id} ({row['rule']}) is informational: resolve it with ack")
            _apply(conn, row["node"], row["rule"], resolution, release)
            _mark_outcome(conn, row["node"], f"resolved:{resolution}")
            if resolution != "continue":
                closed = conn.execute(
                    "UPDATE wakes SET resolved_at = ?, resolution = ? WHERE node = ? AND id != ? AND rule != 'checkpoint' AND resolved_at IS NULL",
                    (time.time(), f"{resolution} (wake {wake_id})", row["node"], wake_id),
                ).rowcount
                detail += f"; closed {closed} other wake(s)" if closed else ""
        conn.execute("UPDATE wakes SET resolved_at = ?, resolution = ? WHERE id = ?", (time.time(), resolution, wake_id))
        _event(conn, row["node"], "resolve", detail)


def _apply(conn, node_id, rule, resolution, release):
    row = _row(conn, node_id)
    status = row["status"]
    if resolution == "continue":
        if rule == "checkpoint":
            _pass_checkpoint(conn, node_id)
        elif status in ("stopped", "failed") and row["report"] is not None:
            conn.execute("UPDATE nodes SET status = 'done', route = 'continue', ended_at = COALESCE(ended_at, ?) WHERE id = ?", (time.time(), node_id))
        else:
            raise TransitionError(f"{node_id} is {status} with no accepted report, so there is nothing to continue")
    elif resolution == "retry":
        if status not in ("stopped", "failed"):
            raise TransitionError(f"{node_id} is {status}, not stopped or failed")
        conn.execute(
            "UPDATE nodes SET status = 'pending', route = NULL, report = NULL, head_sha = NULL, ended_at = NULL, tier = NULL, reason = NULL WHERE id = ?",
            (node_id,),
        )
    elif resolution == "skip":
        if status in ("running", "done"):
            raise TransitionError(f"{node_id} is {status}, so it cannot be skipped")
        conn.execute(
            "UPDATE nodes SET status = 'done', route = ?, ended_at = ? WHERE id = ?",
            ("continue" if release else "skipped", time.time(), node_id),
        )
    else:
        if status == "running":
            raise TransitionError(f"{node_id} is running: wait for it to stop before cancelling")
        if status == "done":
            raise TransitionError(f"{node_id} is done, so it cannot be cancelled")
        conn.execute("UPDATE nodes SET status = 'cancelled', route = 'cancelled' WHERE id = ?", (node_id,))


def fail_internal(conn, node_id, error):
    """Routes a node failed:internal with the error and raises an Opus wake for it, when the dispatcher's own work raised.
    Refused for a done or cancelled node, whose state must not change."""
    with transaction(conn):
        row = _row(conn, node_id)
        if row["status"] in ("done", "cancelled"):
            raise TransitionError(f"{node_id} is {row['status']}, so it cannot fail")
        conn.execute(
            "UPDATE nodes SET status = 'failed', route = 'failed:internal', reason = ?, tier = 'opus', ended_at = ? WHERE id = ?",
            (error, time.time(), node_id),
        )
        _event(conn, node_id, "route", f"failed:internal: {error}")
        _wake(conn, node_id, "opus", "internal", error)


def plan_invalid(conn, error):
    """Records the plan error and raises one plan-invalid wake for it (node '' : the plan has no node). A repeat of the
    error that is already recorded raises nothing. Returns the wake id, or None."""
    with transaction(conn):
        if _plan_error(conn) == error:
            return None
        conn.execute("INSERT OR REPLACE INTO plan_state (id, error) VALUES (1, ?)", (error,))
        return _wake(conn, "", "opus", PLAN_RULE, error)


def plan_valid(conn):
    """Clears the recorded plan error and closes its wake, once plan/dag.toml loads again. Does nothing when no error is recorded."""
    if _plan_error(conn) is None:
        return
    with transaction(conn):
        conn.execute("UPDATE plan_state SET error = NULL WHERE id = 1")
        conn.execute("UPDATE wakes SET resolved_at = ?, resolution = 'fixed' WHERE rule = ? AND resolved_at IS NULL", (time.time(), PLAN_RULE))
        _event(conn, None, "reconcile", "plan valid again")


def _plan_error(conn):
    row = conn.execute("SELECT error FROM plan_state WHERE id = 1").fetchone()
    return row["error"] if row else None


def wake_once(conn, node_id, tier, rule, reason):
    """Raises the wake unless one with this rule is still open for the node. Returns its id, or None."""
    with transaction(conn):
        _row(conn, node_id)
        if conn.execute("SELECT 1 FROM wakes WHERE node = ? AND rule = ? AND resolved_at IS NULL", (node_id, rule)).fetchone():
            return None
        return _wake(conn, node_id, tier, rule, reason)


def open_wakes(conn):
    return conn.execute("SELECT * FROM wakes WHERE resolved_at IS NULL ORDER BY id").fetchall()


def running(conn):
    """The running nodes with their attempt's prompt time, budget and scope, so a restarted dispatcher can watch them
    again as they were started (scope is NULL for an attempt from before migration 4)."""
    return conn.execute(
        "SELECT n.id, n.agent, a.prompt_at, a.budget_turns, a.budget_prompt_k, a.scope FROM nodes n "
        "JOIN attempts a ON a.node = n.id AND a.attempt = n.attempt WHERE n.status = 'running'"
    ).fetchall()


def pause(conn, target, paused=True):
    """Stops new installs for an agent or a node while paused; a running step is left to finish."""
    with transaction(conn):
        if paused:
            conn.execute("INSERT OR IGNORE INTO pauses (target, created_at) VALUES (?, ?)", (target, time.time()))
        else:
            conn.execute("DELETE FROM pauses WHERE target = ?", (target,))


def paused(conn):
    return {row["target"] for row in conn.execute("SELECT target FROM pauses")}


def _pass_checkpoint(conn, node_id):
    """A checkpoint that is not running becomes done with route continue, so its successors may start."""
    row = _row(conn, node_id)
    if row["status"] not in ("pending", "ready", "done"):
        raise TransitionError(f"{node_id} is {row['status']}, so it cannot pass a checkpoint")
    conn.execute(
        "UPDATE nodes SET status = 'done', route = 'continue', ended_at = COALESCE(ended_at, ?) WHERE id = ?",
        (time.time(), node_id),
    )


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


def _wake_once(conn, node_id, rule, reason, this_attempt=False):
    """Raises the wake unless one with this rule is still open for the node or, with this_attempt, was raised
    since the node's current attempt started. Returns 1 when it raised one."""
    if this_attempt:
        seen = conn.execute(
            """SELECT 1 FROM wakes WHERE node = ? AND rule = ? AND created_at >= (
                SELECT a.started_at FROM attempts a JOIN nodes n ON n.id = a.node AND n.attempt = a.attempt
                WHERE n.id = ?)""",
            (node_id, rule, node_id),
        ).fetchone()
    else:
        seen = conn.execute(
            "SELECT 1 FROM wakes WHERE node = ? AND rule = ? AND resolved_at IS NULL", (node_id, rule)
        ).fetchone()
    if seen:
        return 0
    _wake(conn, node_id, "opus", rule, reason)
    return 1
