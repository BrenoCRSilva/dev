#!/usr/bin/env bash
set -euo pipefail

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
make_repo() { mkdir -p "$TASKS_DIR/$1/$2"; : > "$TASKS_DIR/$1/$2/.git"; }
run_task() { TASK_SEARCH=1 "$SESSIONIZER" open "$1"; }
expect_windows() {
    local task=$1 expected=$2 actual
    actual=$(tmux list-windows -t "=$task" -F '#W')
    [[ "$actual" == "$expected" ]] || fail "$task windows were $(printf '%q' "$actual"), expected $(printf '%q' "$expected")"
}

make_repo fixture-multi dotfiles
make_repo fixture-multi api
run_task fixture-multi
expect_windows fixture-multi $'agent\nnvim-dotfiles\nnvim-api\nsrv-dotfiles\nsrv-api'
for expected in "$TASKS_DIR/fixture-multi/dotfiles" "$TASKS_DIR/fixture-multi/api"; do
    grep -Fxq "$expected$(printf '\t.')" "$NVIM_LOG" || fail "nvim . did not launch in $expected"
done

# A live server in a correctly rooted srv tab is kept in place on re-entry.
tmux send-keys -t '=fixture-multi:srv-dotfiles' 'sleep 30' Enter
sleep 0.2
tmux new-window -d -t '=fixture-multi:' -n extra -c "$TASKS_DIR/fixture-multi/dotfiles" 'sleep 30'
tmux select-window -t '=fixture-multi:agent'
active_before=$(tmux list-windows -t '=fixture-multi' -F '#W|#{window_active}' | awk -F'|' '$2 == "1" { print $1 }')
run_task fixture-multi
expect_windows fixture-multi $'agent\nnvim-dotfiles\nnvim-api\nsrv-dotfiles\nsrv-api\nextra'
active_after=$(tmux list-windows -t '=fixture-multi' -F '#W|#{window_active}' | awk -F'|' '$2 == "1" { print $1 }')
[[ "$active_before" == "$active_after" ]] || fail 're-entry changed the active window'
[[ $(tmux display-message -p -t '=fixture-multi:srv-dotfiles' '#{pane_current_command}') == sleep ]] ||
    fail 're-entry replaced a running server process'

make_repo fixture-single onlyrepo
run_task fixture-single
expect_windows fixture-single $'agent\nnvim-onlyrepo\nsrv-onlyrepo'
grep -Fxq "$TASKS_DIR/fixture-single/onlyrepo$(printf '\t.')" "$NVIM_LOG" ||
    fail 'single-repo nvim . did not launch in its worktree'

printf 'PASS: single/multi-repo ordering, nvim cwd, busy srv idempotence, focus, and extra-window preservation\n'
