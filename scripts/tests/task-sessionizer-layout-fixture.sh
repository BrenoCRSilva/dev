#!/usr/bin/env bash
set -euo pipefail
# With TMUX set, tmux ignores TMUX_TMPDIR and uses the caller's server, which this fixture would then kill.
unset TMUX

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SESSIONIZER="$ROOT/env/.config/tmux/scripts/task-sessionizer.sh"
TMP_ROOT=$(mktemp -d)
HOME="$TMP_ROOT/home"
TASKS_DIR="$TMP_ROOT/tasks"
TMUX_TMPDIR="$TMP_ROOT/tmux"
BIN="$TMP_ROOT/bin"
NVIM_LOG="$TMP_ROOT/nvim.log"
export HOME TASKS_DIR TMUX_TMPDIR NVIM_LOG
mkdir -p "$HOME" "$TASKS_DIR" "$TMUX_TMPDIR" "$BIN"
PATH="$BIN:/usr/bin:/bin"
export PATH
cat > "$HOME/.tmux.conf" <<'EOF'
set-option -g default-shell /bin/bash
set-option -g status off
EOF
cat > "$BIN/nvim" <<'EOF'
#!/bin/sh
printf '%s\t%s\n' "$PWD" "$*" >> "$NVIM_LOG"
exec sleep 30
EOF
cat > "$BIN/uwsm-app" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$BIN/herdr" <<'EOF'
#!/bin/sh
case "$*" in
    'session list') exit 0 ;;
    *'workspace list') printf '{"result":{"workspaces":[]}}\n' ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$BIN/nvim" "$BIN/uwsm-app" "$BIN/herdr"

cleanup() {
    TMUX_TMPDIR="$TMUX_TMPDIR" tmux kill-server 2>/dev/null || true
    python3 - "$TMP_ROOT" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# nvim starts a moment after its tmux window, so its log line is polled for up to 10 s.
wait_nvim_line() {
    for _ in $(seq 1 100); do
        grep -Fxq "$1" "$NVIM_LOG" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
# A shell starts its command after send-keys returns, so the pane's command is polled, not slept for.
wait_pane_command() {
    for _ in $(seq 1 100); do
        [[ "$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" == "$2" ]] && return 0
        sleep 0.1
    done
    return 1
}
make_repo() { mkdir -p "$TASKS_DIR/$1/$2"; : > "$TASKS_DIR/$1/$2/.git"; }
run_task() { TASK_SEARCH=1 "$SESSIONIZER" open "$1"; }
expect_windows() {
    local task=$1 expected=$2 actual
    actual=$(tmux list-windows -t "=$task" -F '#W')
    [[ "$actual" == "$expected" ]] || fail "$task windows were $(printf '%q' "$actual"), expected $(printf '%q' "$expected")"
}

make_repo fixture-multi dotfiles
make_repo fixture-multi api
# Older task metadata is the order source when no order file exists.
cat > "$TASKS_DIR/fixture-multi/AGENTS.md" <<'EOF'
# fixture-multi

## Repos
- dotfiles (primary): first repo added
- api: second repo added
EOF
run_task fixture-multi
expect_windows fixture-multi $'agent\nnvim-dotfiles\nnvim-api\nsrv-dotfiles\nsrv-api'
[[ $(cat "$TASKS_DIR/fixture-multi/.task-worker-order") == $'dotfiles\napi' ]] ||
    fail 'legacy AGENTS.md order was not persisted on first use'
for expected in "$TASKS_DIR/fixture-multi/dotfiles" "$TASKS_DIR/fixture-multi/api"; do
    wait_nvim_line "$expected$(printf '\t.')" || fail "nvim . did not launch in $expected"
done

# Open refreshes the managed subagents and keeps one without the marker (C4).
TEMPLATES="$ROOT/env/.config/tmux/scripts/task-roles/subagents"
AGENTS_DIR="$TASKS_DIR/fixture-multi/.claude/agents"
for t in "$TEMPLATES"/*.md; do cmp -s "$t" "$AGENTS_DIR/${t##*/}" || fail "open did not copy ${t##*/}"; done
printf -- '---\nname: diff-reviewer\n---\n<!-- managed: task-roles -->\nold\n' > "$AGENTS_DIR/diff-reviewer.md"
printf 'edited by the user\n' > "$AGENTS_DIR/status-reader.md"
kept=$(run_task fixture-multi 2>&1 >/dev/null)
cmp -s "$TEMPLATES/diff-reviewer.md" "$AGENTS_DIR/diff-reviewer.md" || fail 'open did not refresh a managed subagent'
[[ $(cat "$AGENTS_DIR/status-reader.md") == 'edited by the user' ]] || fail 'open replaced a subagent without the marker'
[[ $kept == *'status-reader.md has no managed marker'*'kept'* ]] || fail "open did not report the kept subagent: $kept"
# An unchanged copy of the pre-marker status-reader template is ours: open refreshes it.
sed '/^effort: high$/d; /^<!-- managed: task-roles -->$/d' "$TEMPLATES/status-reader.md" > "$AGENTS_DIR/status-reader.md"
run_task fixture-multi >/dev/null 2>&1
cmp -s "$TEMPLATES/status-reader.md" "$AGENTS_DIR/status-reader.md" || fail 'open did not refresh a pre-marker copy'

# A live server in a correctly rooted srv tab is kept in place on re-entry.
tmux send-keys -t '=fixture-multi:srv-dotfiles' 'sleep 30' Enter
wait_pane_command '=fixture-multi:srv-dotfiles' sleep || fail 'srv-dotfiles never started its server'
tmux new-window -d -t '=fixture-multi:' -n extra -c "$TASKS_DIR/fixture-multi/dotfiles" 'sleep 30'
tmux select-window -t '=fixture-multi:agent'
active_before=$(tmux list-windows -t '=fixture-multi' -F '#W|#{window_active}' | awk -F'|' '$2 == "1" { print $1 }')
run_task fixture-multi
expect_windows fixture-multi $'agent\nnvim-dotfiles\nnvim-api\nsrv-dotfiles\nsrv-api\nextra'
active_after=$(tmux list-windows -t '=fixture-multi' -F '#W|#{window_active}' | awk -F'|' '$2 == "1" { print $1 }')
[[ "$active_before" == "$active_after" ]] || fail 're-entry changed the active window'
[[ $(tmux display-message -p -t '=fixture-multi:srv-dotfiles' '#{pane_current_command}') == sleep ]] ||
    fail 're-entry replaced a running server process'

# Explicit order metadata takes precedence and remains stable independently of
# AGENTS.md presentation or alphabetical directory order.
make_repo fixture-explicit api
make_repo fixture-explicit dotfiles
cat > "$TASKS_DIR/fixture-explicit/AGENTS.md" <<'EOF'
# fixture-explicit

## Repos
- api: second
- dotfiles: first
EOF
printf '%s\n' dotfiles api > "$TASKS_DIR/fixture-explicit/.task-worker-order"
run_task fixture-explicit
expect_windows fixture-explicit $'agent\nnvim-dotfiles\nnvim-api\nsrv-dotfiles\nsrv-api'

make_repo fixture-single onlyrepo
run_task fixture-single
expect_windows fixture-single $'agent\nnvim-onlyrepo\nsrv-onlyrepo'
wait_nvim_line "$TASKS_DIR/fixture-single/onlyrepo$(printf '\t.')" ||
    fail 'single-repo nvim . did not launch in its worktree'

printf 'PASS: single/multi-repo ordering, nvim cwd, busy srv idempotence, focus, and extra-window preservation\n'
