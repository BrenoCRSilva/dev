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
    has-session)
        [[ -n "${TMUX_HAS_SESSION:-}" && "${3:-}" == "=$TMUX_HAS_SESSION" ]] && exit 0
        exit 1
        ;;
    list-windows) [ -n "${TMUX_WINDOWS:-}" ] && printf '%s\n' $TMUX_WINDOWS; exit 0 ;;
    list-clients) exit 0 ;;
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
cat >/dev/null
if [[ -n "${FZF_OUTPUT_FILE:-}" ]]; then
    cat "$FZF_OUTPUT_FILE"
else
    exit 2
fi
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

# Normal close refuses dirty files and unmerged commits. Explicit force removes
# task worktrees/state but preserves branches for later recovery.
cli_task="$TASKS_DIR/fixture-cli"
cli_worktree="$cli_task/added"
printf 'uncommitted\n' > "$cli_worktree/UNCOMMITTED.md"
if close_output=$("$SESSIONIZER" close fixture-cli 2>&1); then
    fail 'close unexpectedly accepted an uncommitted worktree'
fi
grep -Fq 'added: 1 uncommitted path(s)' <<< "$close_output" || fail "close did not identify dirty worktree: $close_output"
[[ -e "$cli_worktree/.git" ]] || fail 'blocked close changed the dirty worktree'
rm -f "$cli_worktree/UNCOMMITTED.md"
printf 'committed but not merged\n' > "$cli_worktree/UNMERGED.md"
git -C "$cli_worktree" add UNMERGED.md
git -C "$cli_worktree" commit -qm 'fixture unmerged task work'
if close_output=$("$SESSIONIZER" close fixture-cli 2>&1); then
    fail 'close unexpectedly accepted an unmerged task branch'
fi
grep -Fq 'unmerged commit(s)' <<< "$close_output" || fail "close did not identify unmerged commit: $close_output"
[[ -e "$cli_worktree/.git" ]] || fail 'blocked unmerged close changed the worktree'
"$SESSIONIZER" close fixture-cli --force
[[ ! -e "$cli_worktree" && ! -e "$cli_task" ]] || fail 'force close did not remove task worktree and directory'
git -C "$repo_added" show-ref --verify --quiet refs/heads/fixture-cli || fail 'close deleted the task branch'
printf 'PASS: close reports dirty/unmerged work; --force removes task state and keeps branches\n'

# Terminal fzf exposes Ctrl+D as the close action.
[[ ! -s "$FZF_LOG" ]] || fail 'Omarchy popup path unexpectedly invoked terminal fzf'
"$SESSIONIZER" create fixture-fzf --worker "$repo_context"
FZF_OUTPUT_FILE="$TMP_ROOT/fzf-output"; export FZF_OUTPUT_FILE
printf '\nctrl-d\ntask\tfixture-fzf\tfixture task\n' > "$FZF_OUTPUT_FILE"
TASK_SEARCH=1 "$SESSIONIZER" <<< y
[[ ! -d "$TASKS_DIR/fixture-fzf" ]] || fail 'terminal Ctrl+D did not close the clean task'
grep -Fq -- '--expect=ctrl-a,ctrl-d' "$FZF_LOG" || fail 'terminal picker does not bind Ctrl+D to close'
unset FZF_OUTPUT_FILE
printf 'PASS: terminal fzf Ctrl+D closes a selected clean task after confirmation\n'

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
printf 'PASS: popup path invokes every Omarchy selector step; fzf remains terminal-only\n'

# The Omarchy selector has no custom keybinding API, so close is an action,
# task picker, and explicit Close/Cancel confirmation.
queue_file "$MENU_SELECT_CHOICES" \
    $'Close task\taction:close' \
    $'fixture-menu\ttask: worker, context, added (context) on fixture-menu' \
    $'Cancel\tLeave task unchanged'
run_menu
[[ -d "$task" ]] || fail 'cancelled popup close removed its task'
grep -Fxq 'Task to close' "$MENU_SELECT_LOG" || fail 'popup close action did not open task picker'
grep -Fxq 'Close task fixture-menu?' "$MENU_SELECT_LOG" || fail 'popup close action did not ask for explicit confirmation'
printf 'PASS: popup close route can be cancelled safely\n'

queue_file "$MENU_SELECT_CHOICES" \
    $'Close task\taction:close' \
    $'fixture-menu\ttask: running, worker, context, added (context) on fixture-menu' \
    $'Close task\tRemove worktrees and sessions; branches stay'
TMUX_HAS_SESSION=fixture-menu; export TMUX_HAS_SESSION
run_menu
unset TMUX_HAS_SESSION
[[ ! -d "$task" && ! -e "$task/worker" && ! -e "$task/context" ]] || fail 'confirmed popup close left task worktrees or task directory'
git -C "$repo_worker" show-ref --verify --quiet refs/heads/fixture-menu || fail 'popup close deleted worker branch'
git -C "$repo_context" show-ref --verify --quiet refs/heads/fixture-menu || fail 'popup close deleted promoted branch'
grep -Fq 'session stop fixture-menu' "$HERDR_LOG" || fail 'popup close did not stop the Herdr session'
grep -Fq 'session delete fixture-menu' "$HERDR_LOG" || fail 'popup close did not delete the Herdr session record'
grep -Fq 'kill-session -t =fixture-menu' "$TMUX_LOG" || fail 'popup close did not request tmux session removal'
printf 'PASS: confirmed popup close removes task/worktrees and sessions while retaining branches\n'

# --- demote and remove -------------------------------------------------------
# Round trip, refusals, --force, context removal, the last-repo refusal, and the
# Task repos popup flow. Dry runs print every planned action.
dtask="$TASKS_DIR/fixture-demote"
"$SESSIONIZER" create fixture-demote --worker "$repo_worker" --worker "$repo_added" >/dev/null
[[ -e "$dtask/worker/.git" && -e "$dtask/added/.git" ]] || fail 'demote fixture: create failed'

dry=$("$SESSIONIZER" demote fixture-demote worker --dry-run) || fail 'demote dry run failed'
printf 'DRY-RUN demote fixture-demote worker:\n%s\n' "$dry"
[[ -e "$dtask/worker/.git" ]] || fail 'demote dry run removed the worktree'
grep -Fq "branch fixture-demote kept" <<< "$dry" || fail 'demote dry run does not say the branch is kept'

committed=$(git -C "$dtask/worker" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m local && echo ok)
[[ "$committed" == ok ]] || fail 'could not commit in worker worktree'
out=$("$SESSIONIZER" demote fixture-demote worker 2>&1) || fail "demote failed: $out"
grep -Fq 'not merged into' <<< "$out" || fail 'demote did not warn about unmerged commits'
[[ ! -e "$dtask/worker" ]] || fail 'demote left the worktree behind'
git -C "$repo_worker" show-ref --verify --quiet refs/heads/fixture-demote || fail 'demote deleted the branch'
grep -Fxq $'worker\t'"$repo_worker" "$dtask/.task-context.tsv" || fail 'demote did not record worker as context'
grep -Fq "canonical checkout \`$repo_worker\`" "$dtask/AGENTS.md" || fail 'AGENTS.md lacks demoted context entry'
! grep -Fq '**worker** — worktree' "$dtask/AGENTS.md" || fail 'AGENTS.md still lists worker as a worktree'
! grep -Fxq worker "$dtask/.task-worker-order" || fail 'worker order still names demoted repo'

"$SESSIONIZER" promote fixture-demote worker >/dev/null || fail 'promote after demote failed'
[[ -e "$dtask/worker/.git" ]] || fail 'promote did not recreate the worktree'
! grep -Fq $'worker\t' "$dtask/.task-context.tsv" || fail 'promote left worker as context'
grep -Fq '**worker** — worktree' "$dtask/AGENTS.md" || fail 'AGENTS.md lacks promoted worker'
printf 'PASS: demote -> promote round trip keeps the branch and both records\n'

# A dirty worktree is refused, and --force discards it.
printf 'dirty\n' >> "$dtask/worker/README.md"
if out=$("$SESSIONIZER" demote fixture-demote worker 2>&1); then fail 'dirty demote was not refused'; fi
grep -Fq 'uncommitted or untracked' <<< "$out" || fail 'dirty refusal does not name the reason'
[[ -e "$dtask/worker/.git" ]] || fail 'refused demote removed the worktree'
if "$SESSIONIZER" demote fixture-demote worker --dry-run >/dev/null 2>&1; then fail 'dirty dry run was not refused'; fi
"$SESSIONIZER" demote fixture-demote worker --force >/dev/null || fail 'forced demote failed'
[[ ! -e "$dtask/worker" ]] || fail 'forced demote left the worktree'
git -C "$repo_worker" show-ref --verify --quiet refs/heads/fixture-demote || fail 'forced demote deleted the branch'
printf 'PASS: dirty worktree is refused; --force removes it and keeps the branch\n'

# Context repo removal: record and AGENTS.md entry go, branch stays.
dry=$("$SESSIONIZER" remove fixture-demote worker --dry-run) || fail 'remove dry run failed'
printf 'DRY-RUN remove fixture-demote worker (context):\n%s\n' "$dry"
"$SESSIONIZER" remove fixture-demote worker >/dev/null || fail 'remove of context repo failed'
! grep -Fq $'worker\t' "$dtask/.task-context.tsv" 2>/dev/null || fail 'remove left the context record'
! grep -Fq 'canonical checkout `'"$repo_worker"'`' "$dtask/AGENTS.md" || fail 'remove left the AGENTS.md entry'
git -C "$repo_worker" show-ref --verify --quiet refs/heads/fixture-demote || fail 'remove deleted the branch'
printf 'PASS: remove of a context repo drops its record and keeps the branch\n'

# The last repo of a task cannot be removed.
if out=$("$SESSIONIZER" remove fixture-demote added 2>&1); then fail 'last repo was removed'; fi
grep -Fq 'last repo' <<< "$out" || fail 'last-repo refusal does not explain itself'
if "$SESSIONIZER" remove fixture-demote added --dry-run >/dev/null 2>&1; then fail 'last-repo dry run was not refused'; fi
[[ -e "$dtask/added/.git" ]] || fail 'last-repo refusal touched the worktree'
printf 'PASS: last repo of a task is refused\n'

# Window and workspace: the server window closes before the worktree goes.
"$SESSIONIZER" add fixture-demote --worker "$repo_worker" >/dev/null || fail 'add for window test failed'
: > "$TMUX_LOG"
TMUX_WINDOWS="agent nvim-worker srv-worker" "$SESSIONIZER" demote fixture-demote worker >/dev/null || fail 'demote with windows failed'
grep -Fq 'kill-window -t =fixture-demote:srv-worker' "$TMUX_LOG" || fail 'demote did not close the server window'
printf 'PASS: demote closes the repo server window\n'

# Popup: Task repos -> repo -> Demote -> Run (the plan rows precede Run).
detail=$("$SESSIONIZER" rows | awk -F '\t' '$1 == "task" && $2 == "fixture-demote" { print $3 }')
queue_file "$MENU_SELECT_CHOICES" \
    $'Task repos\taction:repos' \
    $'fixture-demote\ttask: '"$detail" \
    $'added\tadded  worker' \
    $'Demote\tremove the worktree; keep the branch' \
    $'Run\tdemote added in fixture-demote'
run_menu
[[ ! -e "$dtask/added" ]] || fail 'popup demote did not remove the worktree'
grep -Fq $'added\t' "$dtask/.task-context.tsv" || fail 'popup demote did not record context'
git -C "$repo_added" show-ref --verify --quiet refs/heads/fixture-demote || fail 'popup demote deleted the branch'
grep -Fxq 'Repos in fixture-demote' "$MENU_SELECT_LOG" || fail 'popup did not open the task repos list'
grep -Fxq 'Demote added in fixture-demote? Plan shown above' "$MENU_SELECT_LOG" || fail 'popup demote did not show its plan before Run'
printf 'PASS: popup Task repos flow demotes a worker after a dry run and Run\n'
