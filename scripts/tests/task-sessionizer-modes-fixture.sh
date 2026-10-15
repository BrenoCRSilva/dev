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
MENU_ROWS_LOG="$TMP_ROOT/menu-rows.log"
export HOME TASKS_DIR TMUX_TMPDIR NVIM_LOG HERDR_LOG TMUX_LOG GIT_LOG MENU_SELECT_LOG MENU_SELECT_CHOICES FZF_LOG MENU_INPUT_LOG MENU_INPUT_CHOICES MENU_ROWS_LOG
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
[ -n "${MENU_ROWS_LOG:-}" ] && printf -- '--- %s\n%s\n' "$prompt" "$rows" >> "$MENU_ROWS_LOG"
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
    $'Create\tstart a new task' \
    $'worker\t'"$(display_path "$repo_worker")" \
    $'WORKER\tCreate a task worktree, nvim/srv windows, and repo agent' \
    $'context\t'"$(display_path "$repo_context")" \
    $'CONTEXT\tRead-only canonical checkout; no worktree or repo agent' \
    $'Finish selection\t1 worker, 1 context chosen'
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
    $'Manage\tmanage a task\'s repos' \
    $'fixture-menu\tworker, context (context) on fixture-menu' \
    $'Add repos\tadd worker or context repos to fixture-menu' \
    $'added\t'"$(display_path "$repo_added")" \
    $'CONTEXT\tRead-only canonical checkout; no worktree or repo agent' \
    $'Finish selection\t0 worker, 1 context chosen' \
    $'Back\treturn to the top level'
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
grep -Fxq 'Manage which task?' "$MENU_SELECT_LOG" || fail 'popup did not invoke the Manage task picker'
grep -Fxq 'Manage fixture-menu' "$MENU_SELECT_LOG" || fail 'popup did not open the Manage list for the task'
grep -Fxq 'Repos for fixture-menu' "$MENU_SELECT_LOG" || fail 'popup did not invoke the create-task repo picker'
grep -Fxq 'Repos to add to fixture-menu' "$MENU_SELECT_LOG" || fail 'popup did not invoke the add-task repo picker'
grep -Fxq 'Repo mode: worker' "$MENU_SELECT_LOG" || fail 'popup did not invoke the worker/context picker'
grep -Fxq 'Repo mode: added' "$MENU_SELECT_LOG" || fail 'popup did not invoke the add-task mode picker'
grep -Fxq 'Name for new task' "$MENU_INPUT_LOG" || fail 'popup did not invoke the create-task name input'
printf 'PASS: popup path invokes every Omarchy selector step; fzf remains terminal-only\n'

# The Omarchy selector has no custom keybinding API, so close is an action,
# task picker, and explicit Close/Cancel confirmation.
queue_file "$MENU_SELECT_CHOICES" \
    $'Remove\tclose a task; worktrees and sessions go, branches stay' \
    $'fixture-menu\tworker, context, added (context) on fixture-menu' \
    $'Cancel\tLeave task unchanged'
run_menu
[[ -d "$task" ]] || fail 'cancelled popup close removed its task'
grep -Fxq 'Task to close' "$MENU_SELECT_LOG" || fail 'popup close action did not open task picker'
grep -Fxq 'Close task fixture-menu?' "$MENU_SELECT_LOG" || fail 'popup close action did not ask for explicit confirmation'
printf 'PASS: popup close route can be cancelled safely\n'

queue_file "$MENU_SELECT_CHOICES" \
    $'Remove\tclose a task; worktrees and sessions go, branches stay' \
    $'fixture-menu\trunning, worker, context, added (context) on fixture-menu' \
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
! grep -Fq $'worker\t' "$dtask/.task-context.tsv" 2>/dev/null || fail 'promote left worker as context'
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
    $'Manage\tmanage a task\'s repos' \
    $'fixture-demote\t'"$detail" \
    $'Demote added\tworker: remove the worktree, keep the branch' \
    $'Run\tdemote added in fixture-demote' \
    $'Back\treturn to the top level'
run_menu
[[ ! -e "$dtask/added" ]] || fail 'popup demote did not remove the worktree'
grep -Fq $'added\t' "$dtask/.task-context.tsv" || fail 'popup demote did not record context'
git -C "$repo_added" show-ref --verify --quiet refs/heads/fixture-demote || fail 'popup demote deleted the branch'
grep -Fxq 'Demote added in fixture-demote? Plan shown above' "$MENU_SELECT_LOG" || fail 'popup demote did not show its plan before Run'
[[ $(grep -Fxc -- '--- Manage fixture-demote' "$MENU_ROWS_LOG") -ge 2 ]] || fail 'demote did not return to the Manage list'
printf 'PASS: Manage demote runs after a dry run and returns to the Manage list\n'

# Popup demote of a dirty worktree: the forced run's Run row and title say
# force, and the refusal it overrides is the first plan row.
"$SESSIONIZER" promote fixture-demote worker >/dev/null || fail 'promote for dirty popup test failed'
printf 'dirty popup\n' >> "$dtask/worker/README.md"
detail=$("$SESSIONIZER" rows | awk -F '\t' '$1 == "task" && $2 == "fixture-demote" { print $3 }')
: > "$MENU_SELECT_LOG"
queue_file "$MENU_SELECT_CHOICES" \
    $'Manage\tmanage a task\'s repos' \
    $'fixture-demote\t'"$detail" \
    $'Demote worker\tworker: remove the worktree, keep the branch' \
    $'Run (force: discards uncommitted work)\tdemote worker in fixture-demote' \
    $'Back\treturn to the top level'
run_menu
grep -Fxq 'Force demote worker in fixture-demote? Discards uncommitted work; plan shown above' "$MENU_SELECT_LOG" ||
    fail 'forced popup demote title does not say force'
grep -Fq 'has uncommitted or untracked changes' "$MENU_ROWS_LOG" || fail 'forced popup demote lacks the refusal plan row'
grep -Fq 'Run (force: discards uncommitted work)' "$MENU_ROWS_LOG" || fail 'forced popup demote Run row lacks the force label'
[[ ! -e "$dtask/worker" ]] || fail 'forced popup demote left the worktree'
git -C "$repo_worker" show-ref --verify --quiet refs/heads/fixture-demote || fail 'forced popup demote deleted the branch'
printf 'PASS: popup forced demote warns about discarded work in its title, plan and Run row\n'

# Popup rows show descriptions only: no internal action:/task: key or plan
# label appears in any visible text (fields 2 and 3; field 1 is the icon).
grep -Fq $'Manage\tmanage a task\'s repos' "$MENU_ROWS_LOG" || fail 'Manage row lacks its description'
if awk -F '\t' '{ for (i = 2; i <= NF; i++) if ($i ~ /^action:/ || $i ~ /^task:/) found = 1 } END { exit found ? 0 : 1 }' "$MENU_ROWS_LOG"; then
    fail 'a popup row shows an internal action:/task: key as visible text'
fi
printf 'PASS: popup rows show no internal action: keys; Manage carries its description\n'

# Flat Manage list for a task with one worker and one context repo, reached
# through the top-level Manage row and the task picker.
"$SESSIONIZER" create fixture-manage --worker "$repo_worker" --context "$repo_added" >/dev/null || fail 'manage fixture create failed'
queue_file "$MENU_SELECT_CHOICES" \
    $'Manage\tmanage a task\'s repos' \
    $'fixture-manage\t'"$("$SESSIONIZER" rows | awk -F '\t' '$1 == "task" && $2 == "fixture-manage" { print $3 }')" \
    $'Back\treturn to the top level'
run_menu
manage_labels=$(awk -F '\t' '$0 == "--- Manage fixture-manage" { delete rows; count = 0; on = 1; next } /^--- / { on = 0 } on { rows[++count] = $2 } END { for (i = 1; i <= count; i++) print rows[i] }' "$MENU_ROWS_LOG")
expected_manage=$'Add repos\nDemote worker\nRemove worker\nPromote added\nRemove added\nBack'
[[ "$manage_labels" == "$expected_manage" ]] || fail "flat Manage list is wrong: $(tr '\n' '|' <<< "$manage_labels")"
top_labels=$(awk -F '\t' '$0 == "--- Tasks" { delete rows; count = 0; on = 1; next } /^--- / { on = 0 } on { rows[++count] = $2 } END { for (i = 1; i <= count; i++) print rows[i] }' "$MENU_ROWS_LOG")
[[ $(tail -n 3 <<< "$top_labels") == $'Manage\nCreate\nRemove' ]] || fail 'top level does not end with Manage, Create, Remove'
while IFS= read -r label; do
    [[ -d "$TASKS_DIR/$label" ]] && continue
    case "$label" in Manage|Create|Remove) ;; *) fail "top level shows a non-task, non-action row: $label" ;; esac
done <<< "$top_labels"
! grep -Fxq 'Task repos' <<< "$top_labels" && ! grep -Fxq 'Add repo to task' <<< "$top_labels" || fail 'top level still shows the old Task repos or Add repo rows'
printf 'PASS: top level shows tasks plus Manage, Create and Remove; Manage lists a worker and a context repo flat\n'

# One task: Manage skips the task picker.
solo="$TMP_ROOT/solo-tasks"
mkdir -p "$solo/solo-task"
queue_file "$MENU_SELECT_CHOICES" \
    $'Manage\tmanage a task\'s repos' \
    $'Back\treturn to the top level'
before_picker=$(grep -Fxc 'Manage which task?' "$MENU_SELECT_LOG")
( export TASKS_DIR="$solo"; run_menu )
[[ $(grep -Fxc 'Manage which task?' "$MENU_SELECT_LOG") -eq "$before_picker" ]] || fail 'Manage asked for a task picker with one task'
grep -Fxq -- '--- Manage solo-task' "$MENU_ROWS_LOG" || fail 'one-task Manage did not open the task list'
printf 'PASS: with one task, Manage opens that task without a picker\n'

# Terminal Manage list: the fzf stub returns Back, so the list closes at once.
printf 'Back\treturn to the top level\n' > "$TMP_ROOT/fzf-back"
FZF_OUTPUT_FILE="$TMP_ROOT/fzf-back"; export FZF_OUTPUT_FILE
"$SESSIONIZER" manage fixture-manage || fail 'terminal manage failed'
unset FZF_OUTPUT_FILE
grep -Fq -- '--prompt manage fixture-manage>' "$FZF_LOG" || fail 'terminal manage did not open the task list'
printf 'PASS: terminal manage opens the task Manage list in fzf\n'

# --- researcher context clones and dry runs ------------------------------------
# A context repo's clone at research/context/<repo> is the researcher's only
# view of it. The clone reads the canonical checkout and writes nothing into it:
# no worktree entry, and no change to the canonical .git from create, refresh or
# close.
canon_state() { find "$1/.git" -printf '%P %s %T@\n' | sort; }
tree_state() { find "$1" -printf '%P %s %T@\n' | sort; }
clone_src="$HOME/Work/group/clonesrc"
make_repo "$clone_src"
printf 'v1\n' > "$clone_src/doc.txt"
git -C "$clone_src" add doc.txt
git -C "$clone_src" commit -qm 'doc v1'
git -C "$clone_src" checkout -q -b feature-x
ctask="$TASKS_DIR/clone-task"
cclone="$ctask/research/context/clonesrc"

before_canon=$(canon_state "$clone_src")
"$SESSIONIZER" create clone-task --worker "$repo_worker" --context "$clone_src" >/dev/null || fail 'clone fixture create failed'
[[ -d "$cclone/.git" && ! -L "$cclone" ]] || fail 'create did not make a clone for the researcher'
[[ $(git -C "$cclone" symbolic-ref --short HEAD) == feature-x ]] || fail 'clone is not on the canonical current branch'
[[ $(git -C "$cclone" config --get remote.origin.url) == "$clone_src" ]] || fail 'clone origin is not the canonical checkout'
[[ $(cat "$cclone/doc.txt") == v1 ]] || fail 'clone does not hold the committed content'
[[ $(git -C "$clone_src" worktree list --porcelain | grep -c '^worktree ') -eq 1 ]] || fail 'clone added a worktree entry to the canonical checkout'
[[ "$(canon_state "$clone_src")" == "$before_canon" ]] || fail 'create wrote into the canonical context checkout'
! [[ -e "$ctask/clonesrc" ]] || fail 'a context repo got a task worktree'
printf 'PASS: create makes a read-only clone of the canonical branch without touching the canonical checkout\n'

# The clone is independent: it moves only on refresh, which fast-forwards it.
printf 'v2\n' > "$clone_src/doc.txt"
git -C "$clone_src" commit -qam 'doc v2'
after_commit=$(canon_state "$clone_src")
[[ $(cat "$cclone/doc.txt") == v1 ]] || fail 'clone moved without a refresh'
refresh_out=$("$SESSIONIZER" refresh clone-task clonesrc) || fail 'refresh failed'
[[ $(cat "$cclone/doc.txt") == v2 ]] || fail 'refresh did not fast-forward the clone'
grep -Fq 'feature-x' <<< "$refresh_out" || fail "refresh did not name the branch: $refresh_out"
[[ "$(canon_state "$clone_src")" == "$after_commit" ]] || fail 'refresh wrote into the canonical context checkout'

# A dirty clone is left alone and refresh says so.
printf 'stray\n' >> "$cclone/doc.txt"
if out=$("$SESSIONIZER" refresh clone-task clonesrc 2>&1); then fail 'refresh overwrote a dirty clone'; fi
grep -Fq 'local changes' <<< "$out" || fail "refresh did not refuse a dirty clone: $out"
[[ $(tail -n 1 "$cclone/doc.txt") == stray ]] || fail 'refusal changed the dirty clone'
git -C "$cclone" checkout -q -- doc.txt

# The clone follows the canonical's current branch, and its detached HEAD.
git -C "$clone_src" checkout -q -b feature-y
"$SESSIONIZER" refresh clone-task clonesrc >/dev/null || fail 'refresh after a branch switch failed'
[[ $(git -C "$cclone" symbolic-ref --short HEAD) == feature-y ]] || fail 'clone did not follow the canonical branch switch'
git -C "$clone_src" checkout -q --detach
"$SESSIONIZER" refresh clone-task clonesrc >/dev/null || fail 'refresh of a detached canonical failed'
[[ -z "$(git -C "$cclone" symbolic-ref --quiet HEAD || true)" ]] || fail 'clone should be detached'
[[ $(git -C "$cclone" rev-parse HEAD) == $(git -C "$clone_src" rev-parse HEAD) ]] || fail 'detached clone is not at the canonical HEAD'
git -C "$clone_src" checkout -q feature-y
if "$SESSIONIZER" refresh clone-task nosuch >/dev/null 2>&1; then fail 'refresh of an unknown repo succeeded'; fi

# A deleted clone is recreated by refresh.
rm -rf "$cclone"
"$SESSIONIZER" refresh clone-task clonesrc | grep -Fq 'recreated' || fail 'refresh did not recreate a missing clone'
[[ -d "$cclone/.git" ]] || fail 'recreated clone is missing'
printf 'PASS: refresh fast-forwards, follows branch and detached switches, refuses dirty clones, and recreates missing ones\n'

# Dry runs change nothing. Create: the plan names the clone.
dry_state=$(tree_state "$TASKS_DIR")
dry_out=$("$SESSIONIZER" create dry-create --worker "$repo_worker" --context "$clone_src" --dry-run) || fail 'create --dry-run failed'
printf 'DRY-RUN create dry-create:\n%s\n' "$dry_out"
grep -Fq 'clonesrc: clone to research/context/clonesrc' <<< "$dry_out" || fail 'create dry run omits the context clone'
grep -Fq 'worker: worktree dry-create/worker on branch dry-create' <<< "$dry_out" || fail 'create dry run omits the worker worktree'
[[ ! -e "$TASKS_DIR/dry-create" ]] || fail 'create dry run created the task'
[[ "$(tree_state "$TASKS_DIR")" == "$dry_state" ]] || fail 'create dry run changed the tasks folder'

# Promote dry run: the clone is still there and nothing moved.
dry_state=$(tree_state "$ctask")
dry_out=$("$SESSIONIZER" promote clone-task clonesrc --dry-run) || fail 'promote --dry-run failed'
printf 'DRY-RUN promote clone-task clonesrc:\n%s\n' "$dry_out"
grep -Fq 'clone:     remove research/context/clonesrc' <<< "$dry_out" || fail 'promote dry run omits the clone removal'
[[ -d "$cclone/.git" && ! -e "$ctask/clonesrc" ]] || fail 'promote dry run changed the clone or created a worktree'
[[ "$(tree_state "$ctask")" == "$dry_state" ]] || fail 'promote dry run changed the task folder'

# Promote removes the clone; demote creates it again.
"$SESSIONIZER" promote clone-task clonesrc >/dev/null || fail 'promote failed'
[[ ! -e "$cclone" && -e "$ctask/clonesrc/.git" ]] || fail 'promote did not remove the clone and create the worktree'
dry_out=$("$SESSIONIZER" demote clone-task clonesrc --dry-run) || fail 'demote --dry-run failed'
grep -Fq 'clone:     create research/context/clonesrc' <<< "$dry_out" || fail 'demote dry run omits the clone creation'
"$SESSIONIZER" demote clone-task clonesrc >/dev/null || fail 'demote failed'
[[ -d "$cclone/.git" && ! -e "$ctask/clonesrc" ]] || fail 'demote did not create the clone and remove the worktree'
printf 'PASS: create, promote and demote keep the clone in step with the context record\n'

# Close: a dry run lists the clone and removes nothing; a dirty clone blocks it.
dry_state=$(tree_state "$ctask")
close_dry=$("$SESSIONIZER" close clone-task --dry-run) || fail 'close --dry-run failed for a clean task'
printf 'DRY-RUN close clone-task:\n%s\n' "$close_dry"
grep -Fq 'research/context/clonesrc (read-only context clone)' <<< "$close_dry" || fail 'close dry run omits the clone'
[[ -d "$cclone/.git" && -d "$ctask" ]] || fail 'close dry run removed the task or its clone'
[[ "$(tree_state "$ctask")" == "$dry_state" ]] || fail 'close dry run changed the task folder'
printf 'stray\n' >> "$cclone/doc.txt"
if out=$("$SESSIONIZER" close clone-task 2>&1); then fail 'close accepted a dirty context clone'; fi
grep -Fq 'uncommitted changes in read-only clone research/context/clonesrc' <<< "$out" || fail "close did not report the dirty clone: $out"
[[ -d "$cclone/.git" ]] || fail 'blocked close removed the clone'
git -C "$cclone" checkout -q -- doc.txt
"$SESSIONIZER" close clone-task >/dev/null 2>&1 || fail 'clean close with a context clone was blocked'
[[ ! -e "$ctask" ]] || fail 'clean close left the task folder'
git -C "$repo_worker" show-ref --verify --quiet refs/heads/clone-task || fail 'close deleted the worker branch'

# Research notes still block a normal close; a clone alone does not.
"$SESSIONIZER" create clone-notes --context "$clone_src" >/dev/null || fail 'notes fixture create failed'
printf 'finding\n' > "$TASKS_DIR/clone-notes/research/notes.md"
if out=$("$SESSIONIZER" close clone-notes 2>&1); then fail 'close accepted research notes'; fi
grep -Fq 'research notes/files' <<< "$out" || fail "close did not report research notes: $out"
if "$SESSIONIZER" close clone-notes --dry-run >/dev/null 2>&1; then fail 'close --dry-run was not refused for research notes'; fi
"$SESSIONIZER" close clone-notes --force >/dev/null || fail 'forced close failed'
[[ ! -e "$TASKS_DIR/clone-notes" ]] || fail 'forced close left the notes task'
printf 'PASS: close dry runs list and remove nothing, a dirty clone or research notes block a normal close, and clean clones go with the task\n'
printf 'PASS: --dry-run plans for create, promote, demote and close name the context clone\n'

# --- orchestrator subagents, allowlist and generated files --------------------
# Subagents are copied into .claude/agents on create when absent; a later write
# keeps a file the user edited. Close treats them as generated only while they
# match the templates, and removes prompts/ with the task.
agents_task="$TASKS_DIR/fixture-agents"
"$SESSIONIZER" create fixture-agents --worker "$repo_worker" >/dev/null || fail 'agents fixture create failed'
for name in status-reader diff-reviewer; do
    cmp -s "$agents_task/.claude/agents/$name.md" "$ROOT/env/.config/tmux/scripts/task-roles/subagents/$name.md" ||
        fail "create did not copy the $name subagent"
done
printf 'edited by the user\n' > "$agents_task/.claude/agents/status-reader.md"
"$SESSIONIZER" add fixture-agents --worker "$repo_added" >/dev/null || fail 'agents fixture add failed'
grep -Fxq 'edited by the user' "$agents_task/.claude/agents/status-reader.md" || fail 'a later write replaced an edited subagent'
for rule in 'Bash(herdr agent wait:*)' 'task-sessionizer.sh refresh:*' 'task-sessionizer.sh promote:*' 'task-sessionizer.sh demote:*'; do
    grep -Fq "$rule" "$agents_task/.claude/settings.json" || fail "orchestrator allowlist lacks $rule"
done
if out=$("$SESSIONIZER" close fixture-agents 2>&1); then fail 'close accepted an edited subagent'; fi
grep -Fq 'custom task-root data in .claude' <<< "$out" || fail "close did not report the edited subagent: $out"
cp "$ROOT/env/.config/tmux/scripts/task-roles/subagents/status-reader.md" "$agents_task/.claude/agents/status-reader.md"
mkdir -p "$agents_task/prompts"
printf 'Read this and follow it.\n' > "$agents_task/prompts/worker-1.md"
"$SESSIONIZER" close fixture-agents >/dev/null 2>&1 || fail 'close blocked by generated subagents or prompts'
[[ ! -e "$agents_task" ]] || fail 'close left the subagent or prompt files behind'
printf 'PASS: subagents are copied on create, kept when edited, and close removes them and prompts/ when generated\n'

# A task made with the previous allowlist is still generated: its close is clean.
legacy_task="$TASKS_DIR/fixture-v1"
"$SESSIONIZER" create fixture-v1 --worker "$repo_worker" >/dev/null || fail 'v1 fixture create failed'
cat > "$legacy_task/.claude/settings.json" <<EOF
{
  "permissions": {
    "allow": [
      "Bash(herdr:*)",
      "Bash(~/.config/tmux/scripts/task-agent.sh:*)",
      "Bash($HOME/.config/tmux/scripts/task-agent.sh:*)"
    ]
  }
}
EOF
if "$SESSIONIZER" close fixture-v1 >/dev/null 2>&1; then
    [[ ! -e "$legacy_task" ]] || fail 'close left the previous-allowlist task behind'
else
    fail 'close flagged a task made with the previous allowlist'
fi
printf 'PASS: a task made with the previous allowlist closes without a custom-data block\n'
