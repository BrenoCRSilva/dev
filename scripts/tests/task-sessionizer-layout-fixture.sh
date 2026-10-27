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
HOOK_LOG="$TMP_ROOT/hook.log"
NVIM_DIRTY="$TMP_ROOT/dirty"
export HOME TASKS_DIR TMUX_TMPDIR NVIM_LOG HOOK_LOG NVIM_DIRTY
mkdir -p "$HOME" "$TASKS_DIR" "$TMUX_TMPDIR" "$BIN" "$NVIM_DIRTY"
PATH="$BIN:/usr/bin:/bin"
export PATH
cat > "$HOME/.tmux.conf" <<'EOF'
set-option -g default-shell /bin/bash
set-option -g status off
EOF
# Fake nvim (its process name is nvim): logs its start, quits on :qa unless
# $NVIM_DIRTY/<its folder name> exists, like a real nvim with unsaved buffers.
cat > "$BIN/nvim" <<'EOF'
#!/bin/bash
# tmux names a pane's command from argv[0], which for a script is bash.
[[ -n "${FAKE_NVIM:-}" ]] || FAKE_NVIM=1 exec -a nvim /bin/bash "$0" "$@"
printf '%s\t%s\n' "$PWD" "$*" >> "$NVIM_LOG"
while IFS= read -r line; do
    [[ "$line" == *:qa* && ! -e "$NVIM_DIRTY/${PWD##*/}" ]] && exit 0
done
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

# Real canonical repos; each .task-hook records where it ran.
make_canonical() {
    local path="$HOME/Projects/$1"
    mkdir -p "$path"
    git -C "$path" init -q
    git -C "$path" config user.name Fixture
    git -C "$path" config user.email fixture@example.invalid
    printf '#!/bin/sh\necho "$TASK $PWD" >> "$HOOK_LOG"\n' > "$path/.task-hook"
    chmod +x "$path/.task-hook"
    git -C "$path" add .task-hook
    git -C "$path" commit -qm init
}
# Pane id of the pane titled srv:<repo> in a session.
srv_pane_of() {
    tmux list-panes -s -t "=$1" -F "#{pane_title}"$'\t'"#{pane_id}" | awk -F '\t' -v t="srv:$2" '$1 == t { print $2 }'
}
wait_file_line() {
    for _ in $(seq 1 100); do
        grep -Fxq "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

# --- create: agent and nvim at the task root, hooks in srv:<repo> panes (C3) ---
make_canonical api
make_canonical web
"$SESSIONIZER" create fixture-new --worker "$HOME/Projects/api" --worker "$HOME/Projects/web" >/dev/null 2>&1 ||
    fail 'create failed'
new="$TASKS_DIR/fixture-new"
expect_windows fixture-new $'agent\nnvim\nsrv'
wait_nvim_line "$(realpath "$new")$(printf '\t.')" || fail 'the shared nvim did not start at the task root'
[[ $(tmux list-panes -t '=fixture-new:nvim' | wc -l) == 1 ]] || fail 'the nvim window has more than one pane'
for repo in api web; do
    pane=$(srv_pane_of fixture-new "$repo")
    [[ -n "$pane" && $(wc -l <<< "$pane") == 1 ]] || fail "no single srv:$repo pane: $(printf '%q' "$pane")"
    [[ $(tmux display-message -p -t "$pane" '#{pane_current_path}') == "$new/$repo" ]] ||
        fail "srv:$repo is not at its worktree"
    wait_file_line "$HOOK_LOG" "fixture-new $new/$repo" || fail "the $repo hook did not run in its worktree"
done
[[ $(tmux list-panes -t '=fixture-new:srv' | wc -l) == 2 ]] || fail 'srv does not hold one pane per repo'
# A program in the pane cannot change the title the panes are found by.
api_pane=$(srv_pane_of fixture-new api)
tmux send-keys -t "$api_pane" "printf '\\033]2;clobbered\\033\\\\'" Enter
sleep 0.3
[[ $(srv_pane_of fixture-new api) == "$api_pane" ]] || fail 'a program renamed the srv:api pane'

# Reopen keeps one pane per repo, and a running server stays in place.
tmux send-keys -t "$api_pane" 'sleep 30' Enter
wait_pane_command "$api_pane" sleep || fail 'srv:api never started its server'
run_task fixture-new
expect_windows fixture-new $'agent\nnvim\nsrv'
[[ $(tmux list-panes -t '=fixture-new:srv' | wc -l) == 2 ]] || fail 'reopen changed the srv panes'
[[ $(tmux display-message -p -t "$api_pane" '#{pane_current_command}') == sleep ]] || fail 'reopen replaced a running server'

# Open refreshes the managed subagents and keeps one without the marker (C4).
TEMPLATES="$ROOT/env/.config/tmux/scripts/task-roles/subagents"
AGENTS_DIR="$new/.claude/agents"
for t in "$TEMPLATES"/*.md; do cmp -s "$t" "$AGENTS_DIR/${t##*/}" || fail "open did not copy ${t##*/}"; done
printf -- '---\nname: diff-reviewer\n---\n<!-- managed: task-roles -->\nold\n' > "$AGENTS_DIR/diff-reviewer.md"
printf 'edited by the user\n' > "$AGENTS_DIR/status-reader.md"
kept=$(run_task fixture-new 2>&1 >/dev/null)
cmp -s "$TEMPLATES/diff-reviewer.md" "$AGENTS_DIR/diff-reviewer.md" || fail 'open did not refresh a managed subagent'
[[ $(cat "$AGENTS_DIR/status-reader.md") == 'edited by the user' ]] || fail 'open replaced a subagent without the marker'
[[ $kept == *'status-reader.md has no managed marker'*'kept'* ]] || fail "open did not report the kept subagent: $kept"
# An unchanged copy of the pre-marker status-reader template is ours: open refreshes it.
sed '/^effort: high$/d; /^<!-- managed: task-roles -->$/d' "$TEMPLATES/status-reader.md" > "$AGENTS_DIR/status-reader.md"
run_task fixture-new >/dev/null 2>&1
cmp -s "$TEMPLATES/status-reader.md" "$AGENTS_DIR/status-reader.md" || fail 'open did not refresh a pre-marker copy'

# Extra windows stay behind the standard ones, and focus does not move.
tmux new-window -d -t '=fixture-new:' -n extra -c "$new/api" 'sleep 30'
tmux swap-window -d -s '=fixture-new:extra' -t '=fixture-new:agent'
tmux select-window -t '=fixture-new:nvim'
run_task fixture-new
expect_windows fixture-new $'agent\nnvim\nsrv\nextra'
active=$(tmux list-windows -t '=fixture-new' -F '#W|#{window_active}' | awk -F'|' '$2 == "1" { print $1 }')
[[ "$active" == nvim ]] || fail "re-entry changed the active window to $active"

# Demote closes the repo's srv pane only.
"$SESSIONIZER" demote fixture-new web >/dev/null 2>&1 || fail 'demote failed'
[[ -z $(srv_pane_of fixture-new web) && -n $(srv_pane_of fixture-new api) ]] || fail 'demote did not close only srv:web'
[[ $(cat "$new/.task-worker-order") == api ]] || fail 'demote did not drop web from the worker order'

# --- reopen of an old-layout task: idle shells and clean nvims close, others stay ---
make_repo fixture-old a
make_repo fixture-old b
printf '# fixture-old\n\n## Repos\n- b: first\n- a: second\n' > "$TASKS_DIR/fixture-old/AGENTS.md"
old="$TASKS_DIR/fixture-old"
tmux new-session -ds fixture-old -n agent -c "$old"
tmux new-window -d -t '=fixture-old:' -n nvim-a -c "$old/a" nvim
tmux new-window -d -t '=fixture-old:' -n nvim-b -c "$old/b" nvim
tmux new-window -d -t '=fixture-old:' -n srv-a -c "$old/a"
tmux new-window -d -t '=fixture-old:' -n srv-b -c "$old/b"
tmux send-keys -t '=fixture-old:srv-b' 'sleep 30' Enter
wait_pane_command '=fixture-old:nvim-a' nvim || fail 'old nvim-a did not start'
wait_pane_command '=fixture-old:nvim-b' nvim || fail 'old nvim-b did not start'
wait_pane_command '=fixture-old:srv-b' sleep || fail 'old srv-b server did not start'
# nvim-b has unsaved buffers: its :qa is refused.
touch "$NVIM_DIRTY/b"
report=$(run_task fixture-old 2>&1 >/dev/null)
# The kept old windows follow agent and nvim (swaps may reorder them).
[[ $(tmux list-windows -t '=fixture-old' -F '#W' | head -n2) == $'agent\nnvim' ]] || fail 'old task does not start with agent, nvim'
[[ $(tmux list-windows -t '=fixture-old' -F '#W' | tail -n +3 | sort) == $'nvim-b\nsrv-b' ]] || fail 'old task kept the wrong windows' 
[[ $(tmux display-message -p -t '=fixture-old:nvim-b' '#{pane_current_command}') == nvim ]] || fail 'the dirty old nvim was ended'
[[ $(tmux display-message -p -t '=fixture-old:srv-b' '#{pane_current_command}') == sleep ]] || fail 'the busy old srv window was ended'
for line in 'closed old window nvim-a (idle)' 'kept old window nvim-b (nvim has unsaved buffers)' \
    'closed old window srv-a (idle)' 'kept old window srv-b (running sleep)'; do
    [[ "$report" == *"layout: $line"* ]] || fail "open did not report: $line; got: $report"
done
[[ $(cat "$old/.task-worker-order") == $'b\na' ]] || fail 'worker order was not rebuilt from AGENTS.md'
wait_nvim_line "$(realpath "$old")$(printf '\t.')" || fail 'the old task did not get the shared nvim'
rm -f "$NVIM_DIRTY/b"

# --- close: the shared nvim quits first; unsaved buffers stop the close ---
touch "$NVIM_DIRTY/fixture-new"
if "$SESSIONIZER" close fixture-new >/dev/null 2>"$TMP_ROOT/close.err"; then fail 'close ran over unsaved nvim buffers'; fi
grep -Fq 'nvim in fixture-new still has unsaved buffers' "$TMP_ROOT/close.err" || fail "close did not explain: $(cat "$TMP_ROOT/close.err")"
[[ -d "$new/api" ]] && tmux has-session -t '=fixture-new' || fail 'a refused close removed something'
plan=$("$SESSIONIZER" close fixture-new --dry-run 2>&1) || true
[[ "$plan" == *'window:    quit nvim (:qa; refused if it has unsaved buffers)'* ]] || fail "close dry run omits the nvim quit: $plan"
rm -f "$NVIM_DIRTY/fixture-new"
tmux respawn-pane -k -t '=fixture-new:nvim' -c "$new" nvim
wait_pane_command '=fixture-new:nvim' nvim || fail 'nvim did not restart'
"$SESSIONIZER" close fixture-new >/dev/null 2>&1 || fail 'clean close failed'
[[ ! -e "$new" ]] || fail 'close left the task folder'
! tmux has-session -t '=fixture-new' 2>/dev/null || fail 'close left the session'
git -C "$HOME/Projects/api" show-ref --verify --quiet refs/heads/fixture-new || fail 'close deleted the branch'

printf 'PASS: shared agent/nvim/srv windows, hooks in srv:<repo> panes found by title, reopen, extra windows and focus, demote, old-layout migration, and close with an unsaved nvim\n'
