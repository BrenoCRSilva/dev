#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SESSIONIZER="$ROOT/env/.config/tmux/scripts/task-sessionizer.sh"
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
TMP_ROOT=$(mktemp -d)
HOME="$TMP_ROOT/home"
TASKS_DIR="$TMP_ROOT/tasks"
TMUX_TMPDIR="$TMP_ROOT/tmux"
BIN="$TMP_ROOT/bin"
NVIM_LOG="$TMP_ROOT/nvim.log"
HERDR_LOG="$TMP_ROOT/herdr.log"
TMUX_LOG="$TMP_ROOT/tmux.log"
GIT_LOG="$TMP_ROOT/git.log"
MENU_SELECT_LOG="$TMP_ROOT/menu-select.log"
MENU_SELECT_CHOICES="$TMP_ROOT/menu-choices"
FZF_LOG="$TMP_ROOT/fzf.log"
MENU_INPUT_LOG="$TMP_ROOT/menu-input.log"
MENU_INPUT_CHOICES="$TMP_ROOT/menu-input-choices"
export HOME TASKS_DIR TMUX_TMPDIR NVIM_LOG HERDR_LOG TMUX_LOG GIT_LOG MENU_SELECT_LOG MENU_SELECT_CHOICES FZF_LOG MENU_INPUT_LOG MENU_INPUT_CHOICES
mkdir -p "$HOME/Projects" "$HOME/Work/group" "$TASKS_DIR" "$TMUX_TMPDIR" "$BIN"
PATH="$BIN:/usr/bin:/bin"
export PATH
cat > "$BIN/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GIT_LOG"
exec /usr/bin/git "$@"
EOF

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
cat > "$BIN/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
    has-session) exit 1 ;;
    list-windows|list-clients) exit 0 ;;
    display-message) exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$BIN/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$*" in
    *'workspace list') printf '{"result":{"workspaces":[]}}\n' ;;
    *'workspace create'*) printf '{"result":{"pane_id":"fixture-pane"}}\n' ;;
    *) exit 0 ;;
esac
EOF
cat > "$BIN/omarchy-menu-select" <<'EOF'
#!/bin/sh
prompt=$1
rows=$(cat)
printf '%s\n' "$prompt" >> "$MENU_SELECT_LOG"
choice=$(head -n 1 "$MENU_SELECT_CHOICES")
awk -F '\t' 'NF >= 2 { if (NF >= 3) print $2 "\t" $3; else print $2 }' <<EOF2 | grep -Fxq -- "$choice" || {
$rows
EOF2
    echo "fixture selection '$choice' not present in '$prompt'" >&2
    exit 2
}
tail -n +2 "$MENU_SELECT_CHOICES" > "$MENU_SELECT_CHOICES.tmp"
mv -f "$MENU_SELECT_CHOICES.tmp" "$MENU_SELECT_CHOICES"
printf '%s\n' "$choice"
EOF
cat > "$BIN/fzf" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FZF_LOG"
exit 2
EOF
cat > "$BIN/omarchy-menu-input" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$MENU_INPUT_LOG"
head -n 1 "$MENU_INPUT_CHOICES"
tail -n +2 "$MENU_INPUT_CHOICES" > "$MENU_INPUT_CHOICES.tmp"
mv -f "$MENU_INPUT_CHOICES.tmp" "$MENU_INPUT_CHOICES"
EOF
chmod +x "$BIN/git" "$BIN/nvim" "$BIN/uwsm-app" "$BIN/tmux" "$BIN/herdr" "$BIN/omarchy-menu-select" "$BIN/omarchy-menu-input" "$BIN/fzf"

cleanup() {
    python3 - "$TMP_ROOT" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; tail -n 25 "$GIT_LOG" >&2 2>/dev/null || true; exit 1; }
make_repo() {
    local path=$1
    mkdir -p "$path"
    git -C "$path" init -q
    git -C "$path" config user.name Fixture
    git -C "$path" config user.email fixture@example.invalid
    printf '%s\n' "$path" > "$path/README.md"
    git -C "$path" add README.md
    git -C "$path" commit -qm init
}
queue_file() {
    local file=$1
    shift
    printf '%s\n' "$@" > "$file"
}
display_path() { printf '%s' "${1/#$HOME/\~}"; }
run_menu() {
    env -u TASK_MENU_CHOICES_FILE -u TASK_MENU_INPUTS_FILE TASK_SEARCH=1 "$SESSIONIZER" popup
}

repo_worker="$HOME/Projects/worker"
repo_context="$HOME/Work/group/context"
repo_added="$HOME/Work/added"
make_repo "$repo_worker"
make_repo "$repo_context"
make_repo "$repo_added"
repo_inventory=$("$SESSIONIZER" list-repos)
grep -Fxq "$repo_worker" <<< "$repo_inventory" || fail 'repo discovery missed ~/Projects checkout'
grep -Fxq "$repo_context" <<< "$repo_inventory" || fail 'repo discovery missed nested ~/Work checkout'
grep -Fxq "$repo_added" <<< "$repo_inventory" || fail 'repo discovery missed ~/Work checkout'

# A legacy task without .task-worker-order takes its order from AGENTS.md and
# persists that order on first layout, even when no tmux session existed.
legacy_task="$TASKS_DIR/fixture-legacy"
mkdir -p "$legacy_task/dotfiles" "$legacy_task/api"
printf 'gitdir: %s\n' "$repo_worker/.git" > "$legacy_task/dotfiles/.git"
printf 'gitdir: %s\n' "$repo_added/.git" > "$legacy_task/api/.git"
cat > "$legacy_task/AGENTS.md" <<'EOF'
# fixture-legacy

## Repos
- dotfiles (primary): first
- api: second
EOF
TASK_SEARCH=1 "$SESSIONIZER" open fixture-legacy
legacy_windows=$(grep 'new-window -d -t =fixture-legacy: -n ' "$TMUX_LOG" | sed 's/.* -n \([^ ]*\).*/\1/')
[[ "$legacy_windows" == $'agent\nnvim-dotfiles\nnvim-api\nsrv-dotfiles\nsrv-api' ]] ||
    fail "legacy task window requests ignored AGENTS.md order: $legacy_windows"
[[ $(cat "$legacy_task/.task-worker-order") == $'dotfiles\napi' ]] ||
    fail 'legacy order was not saved for future opens'

# Create task from the same rows and sequential choices the graphical menu
# consumes: choose WORKER and CONTEXT repos, then finish multi-select.
queue_file "$MENU_SELECT_CHOICES" \
    $'Create new task\taction:create' \
    $'worker\t'"$(display_path "$repo_worker")" \
    $'WORKER\tCreate a task worktree, nvim/srv windows, and repo agent' \
    $'context\t'"$(display_path "$repo_context")" \
    $'CONTEXT\tRead-only canonical checkout; no worktree or repo agent' \
    $'Done\taction:done (1 worker, 1 context)'
queue_file "$MENU_INPUT_CHOICES" fixture-menu
run_menu

task="$TASKS_DIR/fixture-menu"
[[ -d "$task/research" ]] || fail 'new task has no research directory'
[[ -e "$task/worker/.git" ]] || fail 'WORKER choice did not create a git worktree'
[[ ! -e "$task/context" ]] || fail 'CONTEXT choice created a task worktree'
grep -Fq $'context\t'"$repo_context" "$task/.task-context.tsv" || fail 'context checkout was not recorded'
grep -Fq "$repo_context" "$task/AGENTS.md" && grep -Fq 'read-only reference, no task worktree or repo agent' "$task/AGENTS.md" ||
    fail 'AGENTS.md omits read-only context path or boundary'
grep -Fq 'researcher never edits repository trees' "$task/AGENTS.md" || fail 'AGENTS.md omits researcher boundary'

# Add another context through the menu's Add repo to task flow.
queue_file "$MENU_SELECT_CHOICES" \
    $'Add repo to task\taction:add' \
    $'fixture-menu\ttask: worker, context (context) on fixture-menu' \
    $'added\t'"$(display_path "$repo_added")" \
    $'CONTEXT\tRead-only canonical checkout; no worktree or repo agent' \
    $'Done\taction:done (0 worker, 1 context)'
: > "$TMP_ROOT/inputs"
run_menu
grep -Fq $'added\t'"$repo_added" "$task/.task-context.tsv" || fail 'Add repo to task did not record context checkout'

# Explicit promotion changes only the chosen context to a task worker.
"$SESSIONIZER" promote fixture-menu context
[[ -e "$task/context/.git" ]] || fail 'promotion did not create a git worktree'
! grep -Fq $'context\t' "$task/.task-context.tsv" || fail 'promoted repo remains listed as context'
grep -Fq "**context** — worktree" "$task/AGENTS.md" && grep -Fq "$task/context" "$task/AGENTS.md" &&
    grep -Fq "$repo_context" "$task/AGENTS.md" && grep -Fq 'branch `fixture-menu`' "$task/AGENTS.md" ||
    fail 'AGENTS.md was not updated after promotion'
grep -Fq 'new-window -d -t =fixture-menu: -n nvim-worker' "$TMUX_LOG" || fail 'worker nvim window was not requested'
grep -Fq 'new-window -d -t =fixture-menu: -n srv-worker' "$TMUX_LOG" || fail 'worker server window was not requested'
grep -Fq 'new-window -d -t =fixture-menu: -n nvim-context' "$TMUX_LOG" || fail 'promoted repo nvim window was not requested'
grep -Fq 'new-window -d -t =fixture-menu: -n srv-context' "$TMUX_LOG" || fail 'promoted repo server window was not requested'
window_order=$(grep 'new-window -d -t =fixture-menu: -n ' "$TMUX_LOG" | sed 's/.* -n \([^ ]*\).*/\1/' | tail -n 5)
[[ "$window_order" == $'agent\nnvim-worker\nnvim-context\nsrv-worker\nsrv-context' ]] ||
    fail "worker windows were not requested in canonical order: $window_order"
[[ $(cat "$task/.task-worker-order") == $'worker\ncontext' ]] ||
    fail 'worker insertion order was not persisted across promotion'
grep -Fq "workspace create --cwd $task/research --label research" "$HERDR_LOG" || fail 'research workspace was not requested'
! grep -Fq "workspace create --cwd $repo_context" "$HERDR_LOG" || fail 'context repo unexpectedly got a herdr workspace'

# Non-interactive commands share the same worker/context bookkeeping.
"$SESSIONIZER" create fixture-cli --worker "$repo_added" --context "$repo_context"
[[ -e "$TASKS_DIR/fixture-cli/added/.git" ]] || fail 'CLI create did not create worker worktree'
grep -Fq $'context\t'"$repo_context" "$TASKS_DIR/fixture-cli/.task-context.tsv" || fail 'CLI create did not record context repo'
"$SESSIONIZER" add fixture-cli --worker "$repo_worker" --context "$repo_context"
grep -Fq $'worker\t'"$repo_worker" "$TASKS_DIR/fixture-cli/.task-context.tsv" && fail 'CLI add recorded worker as context'
[[ -e "$TASKS_DIR/fixture-cli/worker/.git" ]] || fail 'CLI add did not create worker worktree'

# Agent launcher confines worker metadata write access to the canonical .git
# directory and selects the researcher role/model separately.
repo_args=$("$TASK_AGENT" --dry-run --provider codex start repo context fixture-pane "$repo_context")
[[ "$repo_args" == *'-s workspace-write --add-dir '*"$repo_context/.git"* ]] || fail 'Codex worker lacks scoped canonical .git access'
claude_args=$("$TASK_AGENT" --dry-run --provider claude start repo context fixture-pane "$repo_context")
[[ "$claude_args" == *'--add-dir '*"$repo_context/.git"* && $(grep -o -- '--add-dir' <<< "$claude_args" | wc -l) -eq 1 ]] ||
    fail 'Claude worker lacks scoped canonical .git access'
research_args=$("$TASK_AGENT" --dry-run --provider codex start researcher fixture-pane)
[[ "$research_args" == *'gpt-6-luna'* && "$research_args" != *'--add-dir'* ]] || fail 'researcher launcher has wrong model or repo access'

printf 'PASS: menu create/add, worker/context modes, AGENTS.md recording, research workspace, promotion, stable windows, and scoped agent launch\n'
grep -Fxq 'Tasks' "$MENU_SELECT_LOG" || fail 'popup did not invoke the initial task menu'
grep -Fxq 'Add repo to task' "$MENU_SELECT_LOG" || fail 'popup did not invoke the add-task picker'
grep -Fxq 'Repos for fixture-menu' "$MENU_SELECT_LOG" || fail 'popup did not invoke the create-task repo picker'
grep -Fxq 'Repos to add to fixture-menu' "$MENU_SELECT_LOG" || fail 'popup did not invoke the add-task repo picker'
grep -Fxq 'Repo mode: worker' "$MENU_SELECT_LOG" || fail 'popup did not invoke the worker/context picker'
grep -Fxq 'Repo mode: added' "$MENU_SELECT_LOG" || fail 'popup did not invoke the add-task mode picker'
grep -Fxq 'Name for new task' "$MENU_INPUT_LOG" || fail 'popup did not invoke the create-task name input'
[[ ! -s "$FZF_LOG" ]] || fail 'Omarchy popup path unexpectedly invoked terminal fzf'
printf 'PASS: popup path invokes every Omarchy selector step; fzf remains terminal-only\n'
