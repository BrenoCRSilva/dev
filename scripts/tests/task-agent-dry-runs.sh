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
    for token in '--settings' 'orchestrator.claude-settings' 'repo-agent.claude-settings' '--mcp-config' \
        '--allowedTools' '--plugin-dir' 'mcp_servers.codegraph.command' 'hooks.SessionStart' 'task-assignment.sh' \
        'reports/' 'projects=' '--add-dir' '--permission-mode' '-a on-request' '-s workspace-write'; do
        [[ "$out" == *"$token"* ]] && flags+="$token  "
    done
    printf '%-24s %s\n' "$label" "${flags:-(none)}"
}

echo "codegraph: $(command -v codegraph || echo missing)   ponytail checkout: $(ls -d "$HOME/.local/share/ponytail/v5.2.0" 2> /dev/null || echo missing)"
report 'claude orchestrator' orchestrator
report 'codex orchestrator' --provider codex orchestrator
report 'claude repo' start repo dotfiles worker-pane "$CANON"
report 'codex repo' --provider codex start repo dotfiles worker-pane "$CANON"
report 'claude researcher' start researcher research-pane
report 'codex researcher' --provider codex start researcher research-pane
