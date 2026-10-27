#!/usr/bin/env bash
# Dry runs of every launch task-agent.sh makes, for both providers, printing the
# tool flags each launch gets. Uses the installed codegraph and ponytail when they
# are present. A fake herdr answers the pane lookup with a task layout (a worker
# worktree and the research folder), so the codex trust override and the reports
# folder show. Writes nothing outside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/Projects/dotfiles/.git" "$TMP_ROOT/tasks/fixture/dotfiles" "$TMP_ROOT/tasks/fixture/research"
# Pane ids name the task layout: worker-pane is the worktree, research-pane the research folder.
cat > "$TMP_ROOT/bin/herdr" <<'STUB'
#!/bin/sh
if [ "$1 $2" = "pane get" ]; then
    case "$3" in
        worker-pane) cwd=$TASK_LAYOUT/dotfiles ;;
        research-pane) cwd=$TASK_LAYOUT/research ;;
        *) exit 1 ;;
    esac
    printf '{"result":{"pane":{"cwd":"%s"}}}\n' "$cwd"
    exit 0
fi
exit 1
STUB
chmod +x "$TMP_ROOT/bin/herdr"
TASK_LAYOUT=$(realpath "$TMP_ROOT/tasks/fixture")
export TASK_LAYOUT
PATH="$TMP_ROOT/bin:$PATH"
export PATH
CANON="$TMP_ROOT/Projects/dotfiles"

report() {
    local label=$1 out flags="" token
    shift
    out=$("$TASK_AGENT" --dry-run "$@" 2> /dev/null)
    for token in '--settings' 'orchestrator.claude-settings' 'worker.claude-settings' 'researcher.claude-settings' '--mcp-config' \
        '--allowedTools' '--plugin-dir' 'mcp_servers.codegraph.command' 'hooks.SessionStart' 'task-assignment.sh' \
        'reports/' 'projects=' '--agents' '--add-dir' '--permission-mode' '-a on-request' '-s workspace-write'; do
        [[ "$out" == *"$token"* ]] && flags+="$token  "
    done
    printf '%-24s %s\n' "$label" "${flags:-(none)}"
}

echo "codegraph: $(command -v codegraph || echo missing)   ponytail checkout: $(ls -d "$HOME/.local/share/ponytail/v5.2.0" 2> /dev/null || echo missing)"
report 'claude orchestrator' orchestrator
report 'codex orchestrator' --provider codex orchestrator
report 'claude worker' start worker dotfiles worker-pane "$CANON"
report 'codex worker' --provider codex start worker dotfiles worker-pane "$CANON"
report 'claude researcher' start researcher research-pane
report 'codex researcher' --provider codex start researcher research-pane

# --- helper subagents (C4): claude workers and the researcher get --agents, built from task-roles/subagents ---
fail() { echo "dry runs: FAIL: $*" >&2; exit 1; }
for launch in "start worker dotfiles worker-pane $CANON" "start researcher research-pane"; do
    # shellcheck disable=SC2086
    out=$("$TASK_AGENT" --dry-run $launch 2> /dev/null)
    [[ "$out" == *"--agents "* ]] || fail "claude $launch has no --agents"
done
# shellcheck disable=SC2086
for launch in "orchestrator" "--provider codex start worker dotfiles worker-pane $CANON"; do
    out=$("$TASK_AGENT" --dry-run $launch 2> /dev/null)
    [[ "$out" != *"--agents"* ]] || fail "$launch got --agents"
done
helpers=$("$TASK_AGENT" helpers)
[[ $helpers != *$'\n'* ]] || fail 'helpers JSON is not one line (herdr refuses newlines)'
python3 -I - "$helpers" "$ROOT/env/.config/tmux/scripts/task-roles/subagents" <<'PY' || fail 'helpers JSON does not match the subagent files'
import json, sys
from pathlib import Path
d = json.loads(sys.argv[1])
names = {p.stem for p in Path(sys.argv[2]).glob("*.md")}
assert set(d) == names, (set(d), names)
assert {"web-scout", "repo-scout", "test-runner", "status-reader", "diff-reviewer", "context-scout"} <= names
for name, a in d.items():
    assert "Agent" not in a["tools"], name
    assert a["description"] and a["prompt"] and "managed: task-roles" not in a["prompt"], name
    assert (a["model"], a["effort"]) == (("opus", "medium") if name == "diff-reviewer" else ("haiku", "high")), name
assert d["web-scout"].get("background") is True and "background" not in d["repo-scout"]
for name in ("repo-scout", "context-scout"):
    assert not {"Write", "Edit", "Bash"} & set(d[name]["tools"]), name
for path in Path(sys.argv[2]).glob("*.md"):
    assert "\n<!-- managed: task-roles -->\n" in path.read_text(), path.name
PY
# A copy of the script with a broken subagent file: it is skipped with a warning.
mkdir -p "$TMP_ROOT/copy/task-roles/subagents"
cp "$TASK_AGENT" "$TMP_ROOT/copy/"
cp "$ROOT/env/.config/tmux/scripts/task-roles/subagents/web-scout.md" "$TMP_ROOT/copy/task-roles/subagents/"
printf 'no frontmatter\n' > "$TMP_ROOT/copy/task-roles/subagents/broken.md"
warn=$("$TMP_ROOT/copy/task-agent.sh" helpers 2>&1 >/dev/null)
only=$("$TMP_ROOT/copy/task-agent.sh" helpers 2>/dev/null)
[[ $warn == *'broken.md: no name or description'* ]] || fail "broken subagent not reported: $warn"
[[ $(jq -r 'keys | join(",")' <<< "$only") == web-scout ]] || fail "broken subagent not skipped: $only"
echo 'PASS: claude workers and the researcher get --agents from task-roles/subagents; broken files are skipped'
