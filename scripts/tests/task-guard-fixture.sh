#!/usr/bin/env bash
# task-guard.sh lets a Claude worker's Write, Edit, MultiEdit and NotebookEdit
# change files only in its worktree and in its own reports folder. A blocked
# call exits 2 with the reason on stderr; an allowed one exits 0 with no output.
# The worker is the launch folder (CLAUDE_PROJECT_DIR), so a cd into a sibling
# does not move the guard. Writes only inside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT/env/.config/tmux/scripts/task-guard.sh"
ROLES="$ROOT/env/.config/tmux/scripts/task-roles"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ERR="$TMP_ROOT/stderr"

TASK="$TMP_ROOT/tasks/fixture"
WT="$TASK/dotfiles"
SIBLING="$TASK/api"
CANON="$TMP_ROOT/Projects/dotfiles"
mkdir -p "$WT/env/deep" "$SIBLING" "$TASK/reports/worker-dotfiles" "$TASK/reports/worker-api" \
    "$TASK/reports/researcher" "$TASK/hooks" "$TASK/research" "$CANON/.git" "$TMP_ROOT/outside" "$TMP_ROOT/plain"
git -C "$WT" init -q
git -C "$SIBLING" init -q
# A symlink inside the worktree that points outside it.
ln -s "$TMP_ROOT/outside" "$WT/escape"
# realpath matches what git reports, so the guard and the fixture agree on paths.
TASK=$(realpath "$TASK")
WT=$(realpath "$WT")
SIBLING=$(realpath "$SIBLING")
CANON=$(realpath "$CANON")
PLAIN=$(realpath "$TMP_ROOT/plain")

# call <tool> <path> <cwd>: the hook input Claude sends for one tool call.
call() {
    jq -cn --arg tool "$1" --arg p "$2" --arg cwd "$3" '
        {hook_event_name: "PreToolUse", tool_name: $tool, cwd: $cwd,
         tool_input: (if $tool == "NotebookEdit" then {notebook_path: $p} else {file_path: $p} end)}'
}

# run_guard <project dir> <hook input>: sets STATUS and OUT (stdout) and ERRTEXT (stderr).
run_guard() {
    STATUS=0
    OUT=$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" "$GUARD" 2> "$ERR") || STATUS=$?
    ERRTEXT=$(cat "$ERR")
}

# allow <label> <project> <tool> <path> [cwd]: the call goes through silently.
allow() {
    run_guard "$2" "$(call "$3" "$4" "${5:-$WT}")"
    [[ $STATUS -eq 0 && -z "$OUT" ]] || fail "$1: expected allow, got status $STATUS: $OUT $ERRTEXT"
    printf 'PASS: %s\n' "$1"
}

# block <label> <project> <tool> <path> [cwd]: the call is blocked with a reason.
block() {
    run_guard "$2" "$(call "$3" "$4" "${5:-$WT}")"
    [[ $STATUS -eq 2 && "$ERRTEXT" == task-guard:* ]] || fail "$1: expected block (exit 2 with a reason), got status $STATUS: $OUT $ERRTEXT"
    printf 'PASS: %s\n' "$1"
}

# Inside the worktree and its own reports folder.
allow 'Write inside the worktree' "$WT" Write "$WT/env/deep/new.txt"
allow 'Edit of a worktree file' "$WT" Edit "$WT/README.md"
allow 'MultiEdit inside the worktree' "$WT" MultiEdit "$WT/env/deep/x.sh"
allow 'NotebookEdit inside the worktree (notebook_path)' "$WT" NotebookEdit "$WT/notebook.ipynb"
allow 'a path with .. that stays inside the worktree' "$WT" Write "$WT/env/deep/../deep/y.txt"
allow 'write to its own reports folder' "$WT" Write "$TASK/reports/worker-dotfiles/9.json"

# Outside: the sibling worktree, other agents' reports, the task root, research,
# the canonical checkout, and everything else.
block 'a sibling worktree' "$WT" Write "$SIBLING/file.txt"
block "another worker's reports folder" "$WT" Write "$TASK/reports/worker-api/9.json"
block "the researcher's reports folder" "$WT" Edit "$TASK/reports/researcher/4.json"
block 'the reports root, outside the own folder' "$WT" Write "$TASK/reports/9.json"
block 'the task root (AGENTS.md)' "$WT" Edit "$TASK/AGENTS.md"
block 'the assignment hook (the orchestrator writes it)' "$WT" Write "$TASK/hooks/worker-dotfiles.md"
block 'the research folder' "$WT" Write "$TASK/research/notes.md"
block 'the canonical checkout' "$WT" Write "$CANON/env/x"
block 'a sibling worktree named as a path traversal' "$WT" Write "$WT/../api/file.txt"
block 'a traversal into another reports folder' "$WT" Write "$WT/env/../../reports/worker-api/9.json"
block 'a lookalike folder that starts with the own name' "$WT" Write "$TASK/reports/worker-dotfiles-old/9.json"
block 'a symlink in the worktree that points outside it' "$WT" Write "$WT/escape/passwd"
block 'a relative path' "$WT" Write "env/deep/x.txt"
block 'a call with no file path' "$WT" Write ''

# A cd into a sibling does not move the guard: the worker is the launch folder.
block 'a cd into a sibling does not widen the guard' "$WT" Write "$SIBLING/file.txt" "$SIBLING"
allow 'a cd into a sibling still allows the own worktree' "$WT" Write "$WT/env/deep/z.txt" "$SIBLING"

# Failures to read the situation block the call rather than allow it.
run_guard '' "$(call Write "$WT/env/deep/x.txt" "$WT")"
[[ $STATUS -eq 2 && "$ERRTEXT" == *'CLAUDE_PROJECT_DIR is not set'* ]] || fail "unset CLAUDE_PROJECT_DIR was not blocked: $STATUS $ERRTEXT"
printf 'PASS: without CLAUDE_PROJECT_DIR the guard does not guess the worker from cwd; it blocks\n'
block 'a launch folder that is not a git worktree' "$PLAIN" Write "$PLAIN/x.txt" "$PLAIN"
run_guard "$WT" 'not json'
[[ $STATUS -eq 2 && "$ERRTEXT" == task-guard:* ]] || fail "malformed input was not blocked: $STATUS $ERRTEXT"
printf 'PASS: malformed hook input is blocked\n'

NOJQ="$TMP_ROOT/nojq"
mkdir -p "$NOJQ"
ln -s "$(command -v cat)" "$NOJQ/cat"
STATUS=0
printf '%s' "$(call Write "$WT/x.txt" "$WT")" | env PATH="$NOJQ" CLAUDE_PROJECT_DIR="$WT" "$(command -v bash)" "$GUARD" 2> "$ERR" || STATUS=$?
if [[ $STATUS -ne 2 ]] || ! grep -Fq 'jq is missing' "$ERR"; then
    fail "without jq the guard did not block: $STATUS $(cat "$ERR")"
fi
printf 'PASS: without jq every write is blocked, with the reason\n'

# Only the worker's settings carry the guard; the researcher's do not.
jq -e '.hooks.PreToolUse[] | select(.matcher == "Write|Edit|MultiEdit|NotebookEdit") | .hooks[] | select(.command == "~/.config/tmux/scripts/task-guard.sh")' \
    "$ROLES/worker.claude-settings.json" > /dev/null || fail 'worker settings lack the write guard'
if jq -e '.hooks.PreToolUse' "$ROLES/researcher.claude-settings.json" > /dev/null 2>&1; then
    fail 'researcher settings carry the worker write guard'
fi
jq -e '.hooks.SessionStart' "$ROLES/worker.claude-settings.json" > /dev/null || fail 'worker settings lost the assignment hook'
printf 'PASS: the write guard is wired into the worker settings only\n'
