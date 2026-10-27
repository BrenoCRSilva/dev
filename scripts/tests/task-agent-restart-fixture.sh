#!/usr/bin/env bash
# Offline checks for `task-agent.sh restart orchestrator` and the orchestrator's launch (C4). A stateful
# fake herdr stands in for the session: the orchestrator is idle until /exit ends it. Covers the dry-run
# argv, the refusal outside the orchestrator's pane, the detached finish (idle, and gone), the real
# detached restart, the orchestrator's launch flags and settings hooks, and that worker launches keep
# their old flags. Writes only inside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
SETTINGS="$ROOT/env/.config/tmux/scripts/task-roles/orchestrator.claude-settings.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home" "$TMP/Projects/dotfiles/.git" "$TMP/tasks/fixture/dotfiles" "$TMP/tasks/fixture/research"
echo idle > "$TMP/state/status"
# Fake herdr: records every call. The orchestrator answers `agent get` with its status and pane until
# `agent prompt orchestrator /exit` ends it; `pane run` records the command typed into the pane.
cat > "$TMP/bin/herdr" <<'STUB'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
    "agent get orchestrator")
        [[ -e "$FAKE_STATE/gone" ]] && exit 1
        if [[ -n "${FAKE_VANISH:-}" ]]; then
            [[ -e "$FAKE_STATE/seen" ]] && exit 1
            touch "$FAKE_STATE/seen"
        fi
        printf '{"result":{"agent":{"agent_status":"%s","pane_id":"%s"}}}\n' "$(cat "$FAKE_STATE/status")" "$FAKE_PANE"
        ;;
    "agent prompt orchestrator /exit") touch "$FAKE_STATE/gone" ;;
    "pane run "*) printf '%s' "$4" > "$FAKE_STATE/ran" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/herdr"

export PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/calls.log" FAKE_STATE="$TMP/state" FAKE_PANE=w1:p1
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/xdg"
unset TASK_SESSION TASK_PROVIDER

fail() { echo "restart fixture: FAIL: $*" >&2; exit 1; }
check() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }

# --- the orchestrator's launch -------------------------------------------------
claude_line=$("$TASK_AGENT" --dry-run orchestrator)
for token in 'env ENABLE_CLAUDEAI_MCP_SERVERS=false' 'CLAUDE_CODE_PROMPT_CACHE_TTL=1h' \
    '--strict-mcp-config' 'mcpServers' '--settings' 'orchestrator.claude-settings.json'; do
    check "$claude_line" "$token" 'orchestrator launch'
done
# The full 1M window: no auto-compact cap and no 1M opt-out.
for token in 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' 'CLAUDE_CODE_DISABLE_1M_CONTEXT'; do
    [[ "$claude_line" != *"$token"* ]] || fail "orchestrator launch must not carry $token"
done
for token in '--bare' '--setting-sources' '--disable-slash-commands' 'disableBundledSkills' '--resume' '--continue'; do
    [[ "$claude_line" != *"$token"* ]] || fail "orchestrator launch must not carry $token"
done
# --mcp-config takes several values: the next argument must be an option, or a trailing prompt is read as a config file.
for line in "$claude_line" "$("$TASK_AGENT" --dry-run orchestrator --restarted)"; do
    after_mcp=${line#*'--mcp-config '}; after_mcp=${after_mcp#* }
    [[ "$after_mcp" == --* ]] || fail "orchestrator launch: an option must follow the --mcp-config value, got: ${after_mcp:0:40}"
done
codex_line=$("$TASK_AGENT" --dry-run --provider codex orchestrator)
[[ "$codex_line" != *ENABLE_CLAUDEAI* && "$codex_line" != *strict-mcp* ]] || fail "codex orchestrator gets no claude-only flags"

worker_line=$("$TASK_AGENT" --dry-run start worker dotfiles w2:p1 "$TMP/Projects/dotfiles" 2>/dev/null)
[[ "$worker_line" != *ENABLE_CLAUDEAI* && "$worker_line" != *strict-mcp* ]] || fail "worker launch unchanged"

# The settings file the orchestrator loads keeps its status line, connectors off, and the guard on both events.
jq -e '.disableClaudeAiConnectors == true and .statusLine.type == "command"' "$SETTINGS" >/dev/null || fail "connectors off, status line kept"
for event in UserPromptSubmit PostToolUse; do
    jq -e --arg e "$event" '.hooks[$e][0].hooks[0].command | endswith("task-context-guard.py")' "$SETTINGS" >/dev/null ||
        fail "$event runs the context guard"
done

# --- restart: dry run, refusals ------------------------------------------------
dry=$(HERDR_PANE_ID=w1:p1 "$TASK_AGENT" --dry-run restart orchestrator)
check "$dry" 'restart: wait for the orchestrator in pane w1:p1' 'restart dry run names the pane'
check "$dry" '--restarted' 'restart dry run types the fresh launch'
check "$dry" 'fresh launch (dry run)' 'restart dry run shows the fresh launch'
check "$dry" 'ENABLE_CLAUDEAI_MCP_SERVERS=false' 'fresh launch carries the orchestrator env'
check "$dry" 'Decisions' 'restart kickoff re-asks open decisions'
check "$dry" 'digest' 'restart kickoff reads the dispatcher digest'
check "$dry" 'wake-wait' 'restart kickoff restarts wake-wait'
check "$dry" 'task-dispatch.py\ run' 'restart kickoff reruns run' # the dry run prints the argv escaped
check "$dry" 'TASK_ROLE=orchestrator' 'restart kickoff sets the orchestrator role for run'
check "$dry" 'TASK_JEV_LIVE=1' 'restart kickoff opts run into live jev'
for old in watch status.log queue; do
    [[ "$dry" != *"$old"* ]] || fail "restart kickoff must not mention $old"
done
[[ "$dry" != *"--resume"* && "$dry" != *"--continue"* ]] || fail "restart launches fresh, never --resume"
[[ ! -e "$FAKE_STATE/gone" && ! -e "$FAKE_STATE/ran" ]] || fail "dry run changed state"

if HERDR_PANE_ID=w9:p9 "$TASK_AGENT" restart orchestrator 2>"$TMP/err"; then fail "restart from another pane must refuse"; fi
check "$(cat "$TMP/err")" 'not in pane w9:p9' 'refusal names the pane'
if env -u HERDR_PANE_ID "$TASK_AGENT" restart orchestrator 2>"$TMP/err"; then fail "restart without a pane must refuse"; fi
check "$(cat "$TMP/err")" 'HERDR_PANE_ID is not set' 'refusal without a pane'
if HERDR_PANE_ID=w1:p1 "$TASK_AGENT" restart worker 2>/dev/null; then fail "restart takes only the orchestrator"; fi

# --- the detached finish ---------------------------------------------------------
# Idle orchestrator: /exit first, then the fresh launch typed into the pane, in that order.
: > "$FAKE_LOG"
cmd=$(HERDR_PANE_ID=w1:p1 "$TASK_AGENT" --dry-run restart orchestrator | sed -n '2p' | sed 's/^  //')
out=$("$TASK_AGENT" --restart-finish w1:p1 "task-agent.sh --restarted fixture" 2>&1)
for step in 'waiting for the orchestrator in pane w1:p1' 'orchestrator idle; sending /exit' 'stopped orchestrator' \
    'fresh orchestrator started in pane w1:p1'; do
    check "$out" "$step" 'finish logs each step'
done
[[ $(cat "$FAKE_STATE/ran") == "task-agent.sh --restarted fixture" ]] || fail "finish types the command into the pane"
exit_line=$(grep -n 'agent prompt orchestrator /exit' "$FAKE_LOG" | cut -d: -f1)
run_line=$(grep -n '^pane run ' "$FAKE_LOG" | cut -d: -f1)
(( exit_line < run_line )) || fail "/exit comes before the fresh launch"
[[ -n "$cmd" ]] || fail "dry run prints the pane command"

# Orchestrator already gone: nothing is typed, and the job says so.
rm -f "$FAKE_STATE/ran" "$FAKE_STATE/gone"
touch "$FAKE_STATE/gone"
out=$("$TASK_AGENT" --restart-finish w1:p1 "task-agent.sh --restarted fixture" 2>&1) && fail "finish with no orchestrator must fail"
check "$out" 'no orchestrator agent; nothing done' 'gone orchestrator reported'
[[ ! -e "$FAKE_STATE/ran" ]] || fail "gone orchestrator: pane left alone"
rm -f "$FAKE_STATE/gone"

# The orchestrator is idle when checked, then gone when stop_agent looks: the job logs "did not end" and leaves the pane alone.
rm -f "$FAKE_STATE/ran" "$FAKE_STATE/seen"
out=$(FAKE_VANISH=1 "$TASK_AGENT" --restart-finish w1:p1 "task-agent.sh --restarted fixture" 2>&1) && fail "vanished orchestrator must not restart"
check "$out" 'did not end; not restarted' 'vanished orchestrator is logged by the job'
check "$out" 'By hand: end the orchestrator in pane w1:p1 (/exit), then type there: task-agent.sh --restarted fixture' \
    'give-up names the task-agent.sh command to type'
[[ ! -e "$FAKE_STATE/ran" ]] || fail "vanished orchestrator: pane left alone"
rm -f "$FAKE_STATE/seen"

# --- the real restart: detached, then the fresh launch lands in the pane -------
rm -f "$FAKE_STATE/ran"
out=$(HERDR_PANE_ID=w1:p1 "$TASK_AGENT" restart orchestrator)
check "$out" 'restart: scheduled' 'restart reports it is scheduled'
for _ in $(seq 1 40); do [[ -e "$FAKE_STATE/ran" ]] && break; sleep 0.25; done
[[ -e "$FAKE_STATE/ran" ]] || fail "detached restart never typed the fresh launch"
check "$(cat "$FAKE_STATE/ran")" '--restarted' 'detached restart types the fresh launch'
check "$(cat "$FAKE_STATE/ran")" 'orchestrator' 'fresh launch names the orchestrator'
check "$(cat "$XDG_STATE_HOME/task-agents/restart-orchestrator.log")" 'restart: scheduled for pane w1:p1:' 'the log names the scheduled launch'

echo "task-agent restart fixture: ok"
