#!/usr/bin/env bash
# Repo agents get codegraph and ponytail when both are present; the researcher
# gets codegraph only; the orchestrator gets neither. Each starts without a
# missing tool (with a warning). Codex repo and researcher launches pass a trust
# override for the pane's cwd; the orchestrator's launch is unchanged.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

HOME="$TMP_ROOT/home"
BIN="$TMP_ROOT/bin"
REPO="$TMP_ROOT/Projects/dotfiles"
WORKTREE="$TMP_ROOT/tasks/fixture/dotfiles"
ERR="$TMP_ROOT/stderr"
mkdir -p "$HOME" "$BIN" "$REPO/.git" "$WORKTREE"
WORKTREE_REAL=$(realpath "$WORKTREE")
export HOME
PATH="$BIN:/usr/bin:/bin"
export PATH

# herdr answers "pane get" with the cwd in FIXTURE_PANE_CWD when it is set, and
# fails otherwise. node only has to exist for the presence check.
cat > "$BIN/herdr" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "pane get" ] && [ -n "${FIXTURE_PANE_CWD:-}" ]; then
    printf '{"result":{"pane":{"cwd":"%s"}}}\n' "$FIXTURE_PANE_CWD"
    exit 0
fi
exit 1
EOF
printf '#!/bin/sh\nexit 1\n' > "$BIN/node"
chmod +x "$BIN/herdr" "$BIN/node"

# The trust override as the dry run prints it (printf %q escapes its braces and quotes).
trust_override=$(printf '%q' "projects={\"$WORKTREE_REAL\"={trust_level=\"trusted\"}}")

# --- absent: no codegraph on PATH, no ponytail checkout -------------------
claude_out=$("$TASK_AGENT" --dry-run --provider claude start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
grep -Fq 'codegraph is not on PATH; repo agent starts without it' "$ERR" || fail 'missing codegraph is not reported for repo'
grep -Fq 'ponytail 5.2.0 is not usable' "$ERR" || fail 'missing ponytail checkout is not reported'
[[ "$claude_out" == *'--permission-mode auto --add-dir'* ]] || fail 'absent tools removed the claude repo permission args'
[[ "$claude_out" != *--mcp-config* && "$claude_out" != *--plugin-dir* ]] || fail 'absent tools still added claude flags'

codex_out=$("$TASK_AGENT" --dry-run --provider codex start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
[[ "$codex_out" == *'-a on-request -s workspace-write --add-dir'* ]] || fail 'absent tools removed the codex repo permission args'
[[ "$codex_out" != *mcp_servers* && "$codex_out" != *hooks.* ]] || fail 'absent tools still added codex config'
printf 'PASS: repo agents start without codegraph or ponytail, with a warning\n'

research_out=$("$TASK_AGENT" --dry-run --provider claude start researcher fixture-pane 2> "$ERR")
grep -Fq 'codegraph is not on PATH; researcher agent starts without it' "$ERR" || fail 'missing codegraph is not reported for researcher'
[[ "$(cat "$ERR")" != *ponytail* ]] || fail 'researcher was told about ponytail'
[[ "$research_out" != *--mcp-config* && "$research_out" != *--allowedTools* ]] || fail 'absent codegraph still added researcher MCP flags'
codex_research=$("$TASK_AGENT" --dry-run --provider codex start researcher fixture-pane 2> "$ERR")
[[ "$codex_research" != *mcp_servers* ]] || fail 'absent codegraph still added codex researcher overrides'
printf 'PASS: researcher starts without codegraph, with a warning\n'

# Codex trust needs the pane's cwd; without it, a dry run says so and a real
# start refuses rather than stall on the trust prompt.
codex_untrusted=$("$TASK_AGENT" --dry-run --provider codex start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
[[ "$codex_untrusted" == *'trust: cannot read the cwd of pane fixture-pane'* && "$codex_untrusted" != *'projects='* ]] ||
    fail 'codex repo without a pane cwd did not report the missing trust override'
if "$TASK_AGENT" --provider codex start repo dotfiles fixture-pane "$REPO" > /dev/null 2> "$ERR"; then
    fail 'codex repo started without a trust override'
fi
grep -Fq 'not starting codex without its trust override' "$ERR" || fail 'refused codex start does not say why'
printf 'PASS: codex repo start without a readable pane cwd is refused, not stalled\n'

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

codex_out=$(FIXTURE_PANE_CWD="$WORKTREE" "$TASK_AGENT" --dry-run --provider codex start repo dotfiles fixture-pane "$REPO" 2> "$ERR")
[[ "$codex_out" == *'mcp_servers.codegraph.command='* && "$codex_out" == *'mcp_servers.codegraph.env='* ]] ||
    fail 'codex repo lacks the codegraph MCP overrides'
for event in SessionStart SubagentStart UserPromptSubmit; do
    [[ "$codex_out" == *"hooks.$event="* ]] || fail "codex repo lacks the $event ponytail hook"
done
[[ "$codex_out" == *'PLUGIN_DATA='* ]] || fail 'codex ponytail hooks do not set PLUGIN_DATA'
[[ "${codex_out%%-a on-request*}" == *'hooks.UserPromptSubmit='* ]] || fail 'codex tool overrides must come before the approval flags'
[[ "$codex_out" == *"$trust_override"* ]] || fail 'codex repo lacks the trust override for its pane cwd'
[[ "$codex_out" != *PONYTAIL_QUIET_STARTUP* && "$codex_out" != *PONYTAIL_HIDE_STATUS* ]] ||
    fail 'codex ponytail hooks still set the no-op PONYTAIL_QUIET_STARTUP/PONYTAIL_HIDE_STATUS'
[[ "$codex_out" != *CODEGRAPH_NO_WATCH* && "$claude_out" != *CODEGRAPH_NO_WATCH* ]] || fail 'a repo launch sets CODEGRAPH_NO_WATCH'
printf 'PASS: codex repo agent gets codegraph MCP overrides, the three ponytail hooks and the trust override\n'

# The researcher gets codegraph and nothing else.
research_claude=$(FIXTURE_PANE_CWD="$WORKTREE" "$TASK_AGENT" --dry-run start researcher fixture-pane 2> "$ERR")
[[ "$research_claude" == *'repo-agent.mcp.json'* && "$research_claude" == *'mcp__codegraph__'* ]] ||
    fail 'claude researcher lacks the codegraph MCP config or allow rule'
[[ "$research_claude" == *'repo-agent.claude-settings.json'* && "$research_claude" == *'--permission-mode auto'* ]] ||
    fail 'claude researcher lacks its settings or permission mode'
[[ "$research_claude" != *--plugin-dir* && "$research_claude" != *--add-dir* ]] || fail 'claude researcher got ponytail or repo write access'
research_codex=$(FIXTURE_PANE_CWD="$WORKTREE" "$TASK_AGENT" --dry-run --provider codex start researcher fixture-pane 2> "$ERR")
[[ "$research_codex" == *'mcp_servers.codegraph.command='* && "$research_codex" == *'mcp_servers.codegraph.env='* ]] ||
    fail 'codex researcher lacks the codegraph MCP overrides'
[[ "$research_codex" != *hooks.* && "$research_codex" != *PLUGIN_DATA* && "$research_codex" != *--add-dir* ]] ||
    fail 'codex researcher got ponytail hooks or repo write access'
[[ "$research_codex" == *"$trust_override"* ]] || fail 'codex researcher lacks the trust override for its pane cwd'
[[ "$research_codex" == *'-a on-request -s workspace-write'* ]] || fail 'codex researcher lost its sandbox flags'
printf 'PASS: researcher gets codegraph (both providers) and the codex trust override, but no ponytail and no repo write access\n'

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

# The orchestrator gets no repo tools and no trust override, either provider.
for launch in "orchestrator" "--provider codex orchestrator"; do
    # shellcheck disable=SC2086
    out=$(FIXTURE_PANE_CWD="$WORKTREE" "$TASK_AGENT" --dry-run $launch 2> "$ERR")
    if grep -Eq 'codegraph|ponytail|mcp|plugin-dir|repo-agent|hooks\.|dangerously|projects=' <<< "$out"; then
        fail "'$launch' picked up repo-only tools: $out"
    fi
done
printf 'PASS: orchestrator launches carry no codegraph, ponytail or trust override\n'

# Only the claude orchestrator gets the status line, through its own settings
# file. Repo and researcher launches never see it, so their prompt prefix holds.
claude_orch=$("$TASK_AGENT" --dry-run orchestrator 2> "$ERR")
[[ "$claude_orch" == *"--settings $ROOT/env/.config/tmux/scripts/task-roles/orchestrator.claude-settings.json"* ]] ||
    fail 'claude orchestrator lacks its status line settings'
codex_orch=$("$TASK_AGENT" --dry-run --provider codex orchestrator 2> "$ERR")
[[ "$codex_orch" != *--settings* ]] || fail 'codex orchestrator got claude settings'
for out in "$claude_out" "$research_claude" "$codex_out" "$research_codex"; do
    [[ "$out" != *orchestrator.claude-settings* && "$out" != *statusLine* ]] ||
        fail 'a repo or researcher launch got the orchestrator status line'
done
printf 'PASS: only the claude orchestrator gets the status line settings\n'

# Dry runs must not write state under the home directory.
[[ ! -e "$HOME/.local/state/ponytail" && ! -e "$HOME/.claude.json" ]] || fail 'dry run wrote state under HOME'
printf 'PASS: dry runs write nothing under HOME\n'
