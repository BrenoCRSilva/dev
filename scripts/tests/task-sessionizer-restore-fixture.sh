#!/usr/bin/env bash
# Task open with a saved herdr session (s7). herdr resumes each saved agent pane
# by itself as a bare `claude --resume <id>`, so the sessionizer takes the role
# panes' saved sessions out of session.json before the server starts and starts
# those panes through task-agent.sh --auto: the orchestrator resumes the C1
# record, else the id herdr had saved. A stateful fake herdr serves the saved
# session; a fake claude records the orchestrator's argv. HOME is temporary.
set -euo pipefail
# With TMUX set, tmux ignores TMUX_TMPDIR and uses the caller's server, which this fixture would then kill.
unset TMUX TASK_SESSION TASK_PROVIDER TASK_RESTORED_SESSION XDG_CONFIG_HOME

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SESSIONIZER="$ROOT/env/.config/tmux/scripts/task-sessionizer.sh"
TMP_ROOT=$(mktemp -d)
HOME="$TMP_ROOT/home"
TASKS_DIR="$TMP_ROOT/tasks"
TMUX_TMPDIR="$TMP_ROOT/tmux"
XDG_STATE_HOME="$TMP_ROOT/state"
BIN="$TMP_ROOT/bin"
HERDR_STATE="$TMP_ROOT/herdr"
HERDR_LOG="$TMP_ROOT/herdr.log"
FAKE_CLAUDE="$TMP_ROOT/claude.args"
export HOME TASKS_DIR TMUX_TMPDIR XDG_STATE_HOME HERDR_STATE HERDR_LOG FAKE_CLAUDE
mkdir -p "$HOME" "$TASKS_DIR" "$TMUX_TMPDIR" "$BIN" "$HERDR_STATE"
PATH="$BIN:/usr/bin:/bin"
export PATH
cat > "$HOME/.tmux.conf" <<'EOF'
set-option -g default-shell /bin/bash
set-option -g status off
EOF

# Fake herdr: `server` marks the session running and snapshots session.json as
# the server would restore it; workspaces and panes (w<N>:p1) come from that
# snapshot; pane run and agent start are logged.
cat > "$BIN/herdr" <<'EOF'
#!/bin/bash
s=
[[ ${1:-} == --session ]] && { s=$2; shift 2; }
snap="$HERDR_STATE/at-start.json"
case "$*" in
    'session list') [[ -e $HERDR_STATE/running ]] && printf '%s  running\n' "$(cat "$HERDR_STATE/running")"; exit 0 ;;
    server)
        cp "$HOME/.config/herdr/sessions/$s/session.json" "$snap"
        echo "$s" > "$HERDR_STATE/running" ;;
    'workspace list') jq -c '{result: {workspaces: [.workspaces[] | {label: .custom_name, workspace_id: .id}]}}' "$snap" ;;
    'pane list') jq -c '{result: {panes: [.workspaces[] | {pane_id: (.id + ":p1"), workspace_id: .id}]}}' "$snap" ;;
    'pane get '*)
        jq -c --arg w "${3%%:*}" '{result: {pane: {cwd: (.workspaces[] | select(.id == $w) | .identity_cwd)}}}' "$snap" ;;
    'pane run '*|'agent start '*|'workspace create'*) printf '%s\n' "$*" >> "$HERDR_LOG" ;;
    'agent get '*) echo '{}' ;;
    *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\necho "$@" > "$FAKE_CLAUDE"\n' > "$BIN/claude"
printf '#!/bin/sh\nexec sleep 300\n' > "$BIN/nvim"
printf '#!/bin/sh\nexit 0\n' > "$BIN/uwsm-app"
chmod +x "$BIN/herdr" "$BIN/claude" "$BIN/nvim" "$BIN/uwsm-app"

cleanup() {
    TMUX_TMPDIR="$TMUX_TMPDIR" tmux kill-server 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() { printf 'restore fixture: FAIL: %s\n' "$*" >&2; exit 1; }
check() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }
refute() { [[ "$1" != *"$2"* ]] || fail "$3: did not expect '$2' in: $1"; }
wait_log() {
    for _ in $(seq 1 100); do
        grep -q -- "$1" "$HERDR_LOG" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

# A task with one worker (api), a saved herdr session whose orchestrator, worker
# and researcher panes hold claude sessions, and a hand-made workspace (scratch)
# that must keep its own.
CANON="$HOME/Projects/api"
git init -q "$CANON"
git -C "$CANON" -c user.email=f@x -c user.name=f commit -q --allow-empty -m init
mkdir -p "$TASKS_DIR/t1/research"
git -C "$CANON" worktree add -q "$TASKS_DIR/t1/api" -b t1
echo api > "$TASKS_DIR/t1/.task-worker-order"
TASK=$(realpath "$TASKS_DIR/t1")
SESSION_JSON="$HOME/.config/herdr/sessions/t1/session.json"
H_ORCH=aaaaaaaa-0000-0000-0000-000000000001
H_API=aaaaaaaa-0000-0000-0000-000000000002
H_RES=aaaaaaaa-0000-0000-0000-000000000003
H_SCR=aaaaaaaa-0000-0000-0000-000000000004
ws() { # id label cwd session-id
    jq -nc --arg id "$1" --arg l "$2" --arg c "$3" --arg v "$4" '{id: $id, custom_name: $l, identity_cwd: $c,
        tabs: [{root_pane: 1, panes: {"1": {cwd: $c, agent_session: {source: "herdr:claude", agent: "claude", kind: "id", value: $v}}}}]}'
}
save_session() {
    mkdir -p "${SESSION_JSON%/*}"
    jq -s '{version: 3, workspaces: .}' <(ws w1 t1 "$TASK" $H_ORCH) <(ws w2 api "$TASK/api" $H_API) \
        <(ws w3 research "$TASK/research" $H_RES) <(ws w4 scratch "$TASK" $H_SCR) > "$SESSION_JSON"
}
# Every saved session has a transcript, so --auto may resume it.
mkdir -p "$HOME/.claude/projects/-t"
for id in $H_ORCH $H_API $H_RES; do touch "$HOME/.claude/projects/-t/$id.jsonl"; done
reset_herdr() {
    TMUX_TMPDIR="$TMUX_TMPDIR" tmux kill-server 2>/dev/null || true
    rm -f "$HERDR_STATE"/* "$HERDR_LOG" "$FAKE_CLAUDE"
}
# Runs the orchestrator command the sessionizer typed into pane w1:p1.
run_orchestrator_pane() {
    local cmd
    cmd=$(grep -m1 '^pane run w1:p1 ' "$HERDR_LOG" || true)
    [[ -n $cmd ]] || fail "no orchestrator launch in pane w1:p1: $(cat "$HERDR_LOG" 2>/dev/null)"
    cmd=${cmd#pane run w1:p1 }
    check "$cmd" 'task-agent.sh --provider claude orchestrator --auto' 'orchestrator launch'
    bash -c "$cmd" >/dev/null 2>&1 || fail "orchestrator launch failed: $cmd"
}
record() { jq -r --arg a "$1" '.[$a].session_id // empty' "$TASK/.task-sessions.json"; }

# --- no C1 record: resume herdr's saved ids through task-agent.sh -----------------------
save_session
TASK_SEARCH=1 "$SESSIONIZER" open t1 >/dev/null 2>&1 || fail 'open failed'
snap="$HERDR_STATE/at-start.json"
[[ -f $snap ]] || fail 'open did not start the herdr server'
jq -e '[.workspaces[] | select(.custom_name != "scratch") | .tabs[0].panes["1"].agent_session] | all(. == null)' "$snap" >/dev/null ||
    fail "the server started with role panes still holding a session: $(cat "$snap")"
jq -e --arg v $H_SCR '.workspaces[] | select(.custom_name == "scratch") | .tabs[0].panes["1"].agent_session.value == $v' "$snap" >/dev/null ||
    fail 'a non-role workspace lost its saved session'
jq -e '.workspaces[0].tabs[0].panes["1"].cwd' "$snap" >/dev/null || fail 'the strip dropped other pane fields'
refute "$(cat "$HERDR_LOG" 2>/dev/null)" 'workspace create' 'restored workspaces are not created again'

run_orchestrator_pane
args=$(cat "$FAKE_CLAUDE")
for want in "--resume $H_ORCH" '--model claude-opus-5-5' '--effort medium' '--append-system-prompt-file' '--settings' 'You were resumed'; do
    check "$args" "$want" 'orchestrator without a record'
done
[[ $(record orchestrator) == "$H_ORCH" ]] || fail "the orchestrator's restored id was not recorded: $(cat "$TASK/.task-sessions.json")"

wait_log 'agent start worker-api' || fail "worker api was not started: $(cat "$HERDR_LOG" "$XDG_STATE_HOME/task-agents/restore-t1.log" 2>&1)"
wait_log 'agent start researcher' || fail "the researcher was not started: $(cat "$HERDR_LOG")"
for _ in $(seq 1 50); do [[ -n $(record researcher) && -n $(record worker-api) ]] && break; sleep 0.1; done
w=$(grep 'agent start worker-api' "$HERDR_LOG")
check "$w" '--pane w2:p1' 'worker pane'
check "$w" "--resume $H_API" 'worker resumes its saved id'
check "$w" '--model claude-opus-5-5' 'worker model'
check "$(grep 'agent start researcher' "$HERDR_LOG")" "--resume $H_RES" 'researcher resumes its saved id'
[[ $(record worker-api) == "$H_API" && $(record researcher) == "$H_RES" ]] ||
    fail "worker/researcher records: $(cat "$TASK/.task-sessions.json")"
echo 'PASS: with no record, open strips the role panes and resumes their saved ids through task-agent.sh --auto'

# Reopening with the server running starts nothing again.
n=$(wc -l < "$HERDR_LOG")
TASK_SEARCH=1 "$SESSIONIZER" open t1 >/dev/null 2>&1 || fail 'reopen failed'
sleep 0.3
[[ $(wc -l < "$HERDR_LOG") == "$n" ]] || fail "reopen with a running server relaunched agents: $(cat "$HERDR_LOG")"
echo 'PASS: a reopen with the server running leaves the agents alone'

# --- with a C1 record: the recorded id wins over herdr's -------------------------------
reset_herdr
R_ORCH=bbbbbbbb-0000-0000-0000-000000000001
touch "$HOME/.claude/projects/-t/$R_ORCH.jsonl"
jq --arg s $R_ORCH --arg c "$TASK" '.orchestrator = {provider: "claude", session_id: $s, cwd: $c, updated: "x"}' \
    "$TASK/.task-sessions.json" > "$TMP_ROOT/r" && mv "$TMP_ROOT/r" "$TASK/.task-sessions.json"
save_session
TASK_SEARCH=1 "$SESSIONIZER" open t1 >/dev/null 2>&1 || fail 'open with a record failed'
run_orchestrator_pane
args=$(cat "$FAKE_CLAUDE")
check "$args" "--resume $R_ORCH" 'orchestrator with a record'
refute "$args" "$H_ORCH" 'orchestrator with a record'
[[ $(record orchestrator) == "$R_ORCH" ]] || fail 'the record changed'
wait_log 'agent start researcher' || fail 'the researcher was not started'
echo 'PASS: with a record, the orchestrator resumes the recorded id'

# --- a stale TASK_RESTORED_SESSION never reaches the agents it starts -----------------------
reset_herdr
rm -f "$TASK/.task-sessions.json"
(cd "$TASK" && TASK_RESTORED_SESSION=$H_ORCH "$ROOT/env/.config/tmux/scripts/task-agent.sh" orchestrator >/dev/null 2>&1)
refute "$(cat "$FAKE_CLAUDE")" '--resume' 'a plain start ignores TASK_RESTORED_SESSION'
printf '#!/bin/sh\nenv > "$FAKE_CLAUDE"\n' > "$BIN/claude"
(cd "$TASK" && TASK_RESTORED_SESSION=$H_ORCH "$ROOT/env/.config/tmux/scripts/task-agent.sh" orchestrator --auto >/dev/null 2>&1)
refute "$(cat "$FAKE_CLAUDE")" 'TASK_RESTORED_SESSION' 'the orchestrator inherits TASK_RESTORED_SESSION'
echo 'PASS: TASK_RESTORED_SESSION applies to --auto only and is not passed on'
