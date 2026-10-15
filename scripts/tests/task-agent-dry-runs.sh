#!/usr/bin/env bash
# Dry runs of every launch task-agent.sh makes, for both providers, printing the
# tool flags each launch gets. Uses the installed codegraph and ponytail when they
# are present. A fake herdr answers the pane lookup, so the codex trust override
# shows. Writes nothing outside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/pane" "$TMP_ROOT/Projects/dotfiles/.git"
cat > "$TMP_ROOT/bin/herdr" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "pane get" ]; then
    printf '{"result":{"pane":{"cwd":"%s"}}}\n' "$PANE_CWD"
    exit 0
fi
exit 1
EOF
chmod +x "$TMP_ROOT/bin/herdr"
PANE_CWD=$(realpath "$TMP_ROOT/pane")
export PANE_CWD
PATH="$TMP_ROOT/bin:$PATH"
export PATH
CANON="$TMP_ROOT/Projects/dotfiles"

report() {
    local label=$1 out flags="" token
    shift
    out=$("$TASK_AGENT" --dry-run "$@" 2> /dev/null)
    for token in '--settings' 'orchestrator.claude-settings' 'repo-agent.claude-settings' '--mcp-config' \
        '--allowedTools' '--plugin-dir' 'mcp_servers.codegraph.command' 'hooks.SessionStart' 'projects=' \
        '--add-dir' '--permission-mode' '-a on-request' '-s workspace-write'; do
        [[ "$out" == *"$token"* ]] && flags+="$token  "
    done
    printf '%-24s %s\n' "$label" "${flags:-(none)}"
}

echo "codegraph: $(command -v codegraph || echo missing)   ponytail checkout: $(ls -d "$HOME/.local/share/ponytail/v5.2.0" 2> /dev/null || echo missing)"
report 'claude orchestrator' orchestrator
report 'codex orchestrator' --provider codex orchestrator
report 'claude repo' start repo dotfiles fixture-pane "$CANON"
report 'codex repo' --provider codex start repo dotfiles fixture-pane "$CANON"
report 'claude researcher' start researcher fixture-pane
report 'codex researcher' --provider codex start researcher fixture-pane
