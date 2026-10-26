"""The task plan graph (C5): plan/dag.toml and specs/<id>.md, loaded and validated, and the ready check.

load_plan(task_root) returns the nodes in file order with defaults applied, or raises PlanError with one
line per problem. ready(nodes, state) returns the node ids that may install now; state comes from
task_state.snapshot(). Only the dispatcher reads runtime state through this; the plan itself is Opus's file.
Stdlib only.
"""
import hashlib
import json
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

DEFAULTS = {"session": "fresh", "review": "judge", "budget": {"turns": 60, "prompt_k": 300}}
SESSIONS = ("fresh", "continue")
REVIEWS = ("rules", "judge", "opus")
NODE_KEYS = {"id", "agent", "spec", "after", "scope", "contracts", "checkpoint", "review", "session", "budget"}
DEFAULT_KEYS = {"session", "review", "budget"}
BUDGET_KEYS = {"turns", "prompt_k"}
ID = re.compile(r"[A-Za-z0-9][\w.-]*")
RESERVED_ID = re.compile(r"q\d+")  # generated researcher nodes (task-dispatch.with_questions)
QID = re.compile(r"q:([A-Za-z0-9][\w.-]*)")
FIXED_AGENTS = {"orchestrator", "researcher"}
WORKER_AGENT = re.compile(r"agent `(worker-[A-Za-z0-9._-]+)`")


class PlanError(Exception):
    """The plan is invalid. errors holds one line per problem."""

    def __init__(self, errors):
        super().__init__("; ".join(errors))
        self.errors = errors


@dataclass
class Node:
    id: str
    agent: str
    spec: str | None
    after: list
    scope: list
    contracts: list
    checkpoint: bool
    review: str
    session: str
    budget: dict
    plan_hash: str


def load_plan(task_root):
    """The plan's nodes (id -> Node) in file order, with defaults applied. Raises PlanError on any problem."""
    root = Path(task_root)
    path = root / "plan" / "dag.toml"
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except OSError:
        raise PlanError(["plan/dag.toml: missing"])
    except tomllib.TOMLDecodeError as error:
        raise PlanError([f"plan/dag.toml: {error}"])
    errors = [f"plan/dag.toml: unknown table {key}" for key in sorted(set(data) - {"defaults", "node"})]
    defaults = _defaults(data.get("defaults", {}), errors)
    agents = _known_agents(root, errors)
    raw_nodes = data.get("node", [])
    if not isinstance(raw_nodes, list):
        raise PlanError([*errors, "plan/dag.toml: node must be an array of [[node]] tables"])
    nodes = {}
    invalid = set()
    for index, raw in enumerate(raw_nodes, 1):
        node = _node(root, index, raw, defaults, agents, errors)
        if node is None:
            if isinstance(raw, dict) and isinstance(raw.get("id"), str):
                invalid.add(raw["id"])
            continue
        if node.id in nodes:
            errors.append(f"node {node.id}: duplicate id")
        else:
            nodes[node.id] = node
    errors += _graph_errors(nodes, invalid)
    if errors:
        raise PlanError(errors)
    return nodes


def ready(nodes, state):
    """Ids of the nodes that may install now, in file order.

    A node is ready when it is pending or ready, every after dep is routed continue (or its q: question is
    answered) with no open blocking question of its own, its agent has no running node, and no earlier ready node
    in this list is for that agent.
    state is task_state.snapshot(): {"nodes": {id: row}, "answered": {qid}, "blocking": {node: [open qid]}}.
    """
    rows = state["nodes"]
    busy = {row["agent"] for row in rows.values() if row["status"] == "running"}
    picked = []
    for node in nodes.values():
        row = rows.get(node.id)
        if row is None or row["status"] not in ("pending", "ready") or node.agent in busy:
            continue
        if all(_satisfied(dep, rows, state["answered"]) for dep in node.after) and not any(
            state["blocking"].get(dep) for dep in node.after
        ):
            busy.add(node.agent)
            picked.append(node.id)
    return picked


def _satisfied(dep, rows, answered):
    question = QID.fullmatch(dep)
    if question:
        return question[1] in answered
    return rows.get(dep, {}).get("route") == "continue"


def _known_agents(root, errors):
    agents = set(FIXED_AGENTS)
    try:
        text = (root / "AGENTS.md").read_text(encoding="utf-8")
    except OSError:
        errors.append("AGENTS.md: missing, so worker agents cannot be checked")
        return agents
    repo_modes = text.split("## Repo modes", 1)[-1].split("\n## ", 1)[0]
    agents.update(WORKER_AGENT.findall(repo_modes))
    return agents


def _defaults(raw, errors):
    if not isinstance(raw, dict):
        errors.append("defaults: must be a table")
        raw = {}
    for key in sorted(set(raw) - DEFAULT_KEYS):
        errors.append(f"defaults: unknown key {key}")
    return {
        "session": _choice(raw.get("session", DEFAULTS["session"]), SESSIONS, "defaults", "session", errors),
        "review": _choice(raw.get("review", DEFAULTS["review"]), REVIEWS, "defaults", "review", errors),
        "budget": {**DEFAULTS["budget"], **_budget(raw.get("budget", {}), "defaults", errors)},
    }


def _node(root, index, raw, defaults, agents, errors):
    where = f"node #{index}"
    if not isinstance(raw, dict):
        errors.append(f"{where}: must be a table")
        return None
    node_id = raw.get("id")
    if not (isinstance(node_id, str) and ID.fullmatch(node_id)):
        errors.append(f"{where}: id must be a name such as web-11")
        return None
    if RESERVED_ID.fullmatch(node_id):
        errors.append(f"{where}: id {node_id} is reserved for a researcher node (q<qid>)")
        return None
    where = f"node {node_id}"
    for key in sorted(set(raw) - NODE_KEYS):
        errors.append(f"{where}: unknown key {key}")
    agent = raw.get("agent")
    if not isinstance(agent, str):
        errors.append(f"{where}: agent must be a name")
    elif agent not in agents:
        errors.append(f"{where}: unknown agent {agent!r}")
    checkpoint = raw.get("checkpoint", False)
    if not isinstance(checkpoint, bool):
        errors.append(f"{where}: checkpoint must be true or false")
    spec = raw.get("spec")
    spec_ok = spec is not None and _inside(root, spec) and (root / spec).is_file()
    if spec is None and checkpoint is not True:
        errors.append(f"{where}: spec is required unless the node is a checkpoint")
    elif spec is not None and not _inside(root, spec):
        errors.append(f"{where}: spec {spec!r} must be a relative path inside the task root")
    elif spec is not None and not spec_ok:
        errors.append(f"{where}: spec file {spec!r} not found")
    scope = _strings(raw.get("scope", []), where, "scope", errors)
    if isinstance(agent, str) and agent.startswith("worker-") and not scope:
        errors.append(f"{where}: a worker node needs scope globs")
    errors += [f"{where}: scope {glob} must be relative, without .." for glob in scope if _escapes(glob)]
    fields = {
        "id": node_id,
        "agent": agent,
        "spec": spec,
        "after": _strings(raw.get("after", []), where, "after", errors),
        "scope": scope,
        "contracts": _strings(raw.get("contracts", []), where, "contracts", errors),
        "checkpoint": checkpoint is True,
        "review": _choice(raw.get("review", defaults["review"]), REVIEWS, where, "review", errors),
        "session": _choice(raw.get("session", defaults["session"]), SESSIONS, where, "session", errors),
        "budget": {**defaults["budget"], **_budget(raw.get("budget", {}), where, errors)},
    }
    text = (root / spec).read_text(encoding="utf-8") if spec_ok else ""
    digest = hashlib.sha256(json.dumps({**fields, "spec_text": text}, sort_keys=True, default=str).encode()).hexdigest()
    return Node(**fields, plan_hash=digest[:16])


def _escapes(glob):
    """True for an absolute path or one with a .. segment, which would leave the worktree."""
    path = PurePosixPath(glob)
    return path.is_absolute() or ".." in path.parts


def _inside(root, rel):
    """True when rel is a relative path that stays inside root, symlinks included."""
    return isinstance(rel, str) and not _escapes(rel) and (root / rel).resolve().is_relative_to(root.resolve())


def _graph_errors(nodes, invalid):
    errors = []
    for node in nodes.values():
        for dep in node.after:
            if not QID.fullmatch(dep) and dep not in nodes and dep not in invalid:
                errors.append(f"node {node.id}: after {dep} is neither a node id nor q:<qid>")
    cycle = _find_cycle(nodes)
    if cycle:
        errors.append(f"cycle: {' -> '.join(cycle)}")
    return errors


def _find_cycle(nodes):
    """The first cycle in the after edges between nodes, as ids with the first id repeated, or None."""
    seen = {}
    stack = []

    def visit(node_id):
        seen[node_id] = "open"
        stack.append(node_id)
        for dep in nodes[node_id].after:
            if dep not in nodes:
                continue
            if seen.get(dep) == "open":
                return stack[stack.index(dep):] + [dep]
            if dep not in seen and (found := visit(dep)):
                return found
        stack.pop()
        seen[node_id] = "done"
        return None

    for node_id in nodes:
        if node_id not in seen and (found := visit(node_id)):
            return found
    return None


def _choice(value, options, where, key, errors):
    if value not in options:
        errors.append(f"{where}: {key} must be one of {', '.join(options)}")
    return value


def _strings(value, where, key, errors):
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        errors.append(f"{where}: {key} must be a list of non-empty strings")
        return []
    return list(value)


def _budget(value, where, errors):
    valid = isinstance(value, dict) and set(value) <= BUDGET_KEYS
    valid = valid and all(isinstance(v, int) and not isinstance(v, bool) and v > 0 for v in value.values())
    if not valid:
        errors.append(f"{where}: budget takes turns and prompt_k, as positive integers")
        return {}
    return dict(value)
