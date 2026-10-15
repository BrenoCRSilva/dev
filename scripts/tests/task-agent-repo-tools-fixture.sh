#!/usr/bin/env bash
# Repo agents get codegraph and ponytail when both are present, and start
# without a missing one (with a warning). Orchestrator and researcher launches
# get neither, for either provider.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

HOME="$TMP_ROOT/home"
BIN="$TMP_ROOT/bin"
REPO="$TMP_ROOT/Projects/dotfiles"
ERR="$TMP_ROOT/stderr"
mkdir -p "$HOME" "$BIN" "$REPO/.git"
export HOME
PATH="$BIN:/usr/bin:/bin"
export PATH

# herdr is stubbed so the claude trust lookup finds nothing; node only has to
# exist for the presence check.
for stub in herdr node; do
    printf '#!/bin/sh\nexit 1\n' > "$BIN/$stub"
    chmod +x "$BIN/$stub"
done

# --- absent: no codegraph on PATH, no ponytail checkout -------------------
claude_out=$("$TASK_AGENT" --dry-run --provider claude start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
grep -Fq 'codegraph is not on PATH' "$ERR" || fail 'missing codegraph is not reported'
grep -Fq 'ponytail 5.2.0 is not usable' "$ERR" || fail 'missing ponytail checkout is not reported'
[[ "$claude_out" == *'--permission-mode auto --add-dir'* ]] || fail 'absent tools removed the claude repo permission args'
[[ "$claude_out" != *--mcp-config* && "$claude_out" != *--plugin-dir* ]] || fail 'absent tools still added claude flags'

codex_out=$("$TASK_AGENT" --dry-run --provider codex start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
[[ "$codex_out" == *'-a on-request -s workspace-write --add-dir'* ]] || fail 'absent tools removed the codex repo permission args'
[[ "$codex_out" != *mcp_servers* && "$codex_out" != *hooks.* ]] || fail 'absent tools still added codex config'
printf 'PASS: repo agents start without codegraph or ponytail, with a warning\n'

# --- present: stub codegraph and a pinned ponytail checkout ---------------
printf '#!/bin/sh\nexit 0\n' > "$BIN/codegraph"
chmod +x "$BIN/codegraph"
PONYTAIL="$HOME/.local/share/ponytail/v5.2.0"
mkdir -p "$PONYTAIL/.claude-plugin" "$PONYTAIL/hooks"
printf '{"name":"ponytail"}\n' > "$PONYTAIL/.claude-plugin/plugin.json"
for hook in ponytail-activate ponytail-subagent ponytail-mode-tracker; do
    printf '// stub\n' > "$PONYTAIL/hooks/$hook.js"
done

claude_out=$("$TASK_AGENT" --dry-run --provider claude start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
if grep -v '^trust:' "$ERR" | grep -q .; then fail "present tools still warned: $(cat "$ERR")"; fi
[[ "$claude_out" == *'repo-agent.mcp.json'* && "$claude_out" == *'mcp__codegraph__'* ]] || fail 'claude repo lacks the codegraph MCP config or allow rule'
[[ "$claude_out" == *"--plugin-dir $PONYTAIL"* ]] || fail 'claude repo lacks the ponytail plugin dir'
[[ "$claude_out" == *'repo-agent.claude-settings.json'* ]] || fail 'claude repo lacks its settings file'
[[ "${claude_out%%--add-dir*}" == *--plugin-dir* && "${claude_out%%--add-dir*}" == *--mcp-config* ]] ||
    fail 'claude tool flags must come before the variadic --add-dir'
[[ $(grep -o -- '--add-dir' <<< "$claude_out" | wc -l) -eq 1 ]] || fail 'claude repo has more than one --add-dir'
printf 'PASS: claude repo agent gets codegraph MCP, its allow rule, the ponytail plugin and its settings\n'

codex_out=$("$TASK_AGENT" --dry-run --provider codex start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
[[ "$codex_out" == *'mcp_servers.codegraph.command='* && "$codex_out" == *'mcp_servers.codegraph.env='* ]] ||
    fail 'codex repo lacks the codegraph MCP overrides'
for event in SessionStart SubagentStart UserPromptSubmit; do
    [[ "$codex_out" == *"hooks.$event="* ]] || fail "codex repo lacks the $event ponytail hook"
done
[[ "$codex_out" == *'PLUGIN_DATA='* ]] || fail 'codex ponytail hooks do not set PLUGIN_DATA'
[[ "${codex_out%%-a on-request*}" == *'hooks.UserPromptSubmit='* ]] || fail 'codex tool overrides must come before the approval flags'
[[ "$codex_out" != *PONYTAIL_QUIET_STARTUP* && "$codex_out" != *PONYTAIL_HIDE_STATUS* ]] ||
    fail 'codex ponytail hooks still set the no-op PONYTAIL_QUIET_STARTUP/PONYTAIL_HIDE_STATUS'
[[ "$codex_out" != *CODEGRAPH_NO_WATCH* && "$claude_out" != *CODEGRAPH_NO_WATCH* ]] || fail 'a repo launch sets CODEGRAPH_NO_WATCH'
printf 'PASS: codex repo agent gets codegraph MCP overrides and the three ponytail hooks\n'

# The claude settings file carries only the codegraph telemetry switch.
SETTINGS="$ROOT/env/.config/tmux/scripts/task-roles/repo-agent.claude-settings.json"
grep -Fq '"CODEGRAPH_TELEMETRY": "0"' "$SETTINGS" || fail 'repo settings lost CODEGRAPH_TELEMETRY=0'
if grep -q 'PONYTAIL_' "$SETTINGS"; then fail 'repo settings still set no-op PONYTAIL_* variables'; fi
if grep -rq 'CODEGRAPH_NO_WATCH' "$ROOT/env/.config/tmux/scripts"; then fail 'a tracked launcher file sets CODEGRAPH_NO_WATCH'; fi
printf 'PASS: repo settings set only CODEGRAPH_TELEMETRY; nothing sets CODEGRAPH_NO_WATCH\n'

# The tracked global ignore must hide a symlinked .codegraph (index kept outside
# the worktree), which a trailing-slash pattern would not match.
IGN_TEST="$TMP_ROOT/ignore-test"
mkdir -p "$IGN_TEST/xdg/git" "$IGN_TEST/repo" "$IGN_TEST/external"
cp "$ROOT/env/.config/git/ignore" "$IGN_TEST/xdg/git/ignore"
git -C "$IGN_TEST/repo" init -q
printf 'x\n' > "$IGN_TEST/repo/file.txt"
ln -s "$IGN_TEST/external" "$IGN_TEST/repo/.codegraph"
touch "$IGN_TEST/external/codegraph.db"
ignored_status=$(XDG_CONFIG_HOME="$IGN_TEST/xdg" git -C "$IGN_TEST/repo" status --porcelain --untracked-files=all)
[[ "$ignored_status" == '?? file.txt' ]] || fail "tracked ignore does not hide the symlinked .codegraph: $ignored_status"
printf 'PASS: tracked global ignore hides a symlinked .codegraph index\n'

# --- orchestrator and researcher get no repo tools, either provider -------
for launch in "orchestrator" "--provider codex orchestrator" "start researcher fixture-pane" "--provider codex start researcher fixture-pane"; do
    # shellcheck disable=SC2086
    out=$("$TASK_AGENT" --dry-run $launch 2> "$ERR")
    if grep -Eq 'codegraph|ponytail|mcp|plugin-dir|--settings|hooks\.|dangerously' <<< "$out"; then
        fail "'$launch' picked up repo-only tools: $out"
    fi
done
printf 'PASS: orchestrator and researcher launches carry no repo-only tools\n'

# Dry runs must not write state under the home directory.
[[ ! -e "$HOME/.local/state/ponytail" ]] || fail 'dry run created the ponytail state dir'
printf 'PASS: dry runs write nothing under HOME\n'
