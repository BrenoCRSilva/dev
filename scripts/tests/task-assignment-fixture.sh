#!/usr/bin/env bash
# task-assignment.sh adds the assignment file of the agent whose folder the
# session starts in: a worker's worktree (or a folder inside it) gets
# hooks/worker-<repo>.md, the research folder gets hooks/researcher.md. It prints
# nothing when there is no file, no such folder, or no jq. Its output is the
# SessionStart JSON with the file's text, unchanged, as additionalContext.
# Writes only inside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/env/.config/tmux/scripts/task-assignment.sh"
BASH_BIN=$(command -v bash)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TASK="$TMP_ROOT/tasks/fixture"
WORKTREE="$TASK/dotfiles"
mkdir -p "$TASK/hooks" "$TASK/research" "$WORKTREE/env/deep"
git -C "$WORKTREE" init -q
# Quotes, a backslash, a newline and a non-ASCII character must survive as JSON.
DOTFILES_TEXT=$'# dotfiles: step 9\nScope: "env/" only, C4 \\ report\nDone when: café checks pass'
RESEARCH_TEXT='# researcher: step 4'
printf '%s\n' "$DOTFILES_TEXT" > "$TASK/hooks/worker-dotfiles.md"
printf '%s\n' "$RESEARCH_TEXT" > "$TASK/hooks/researcher.md"

# run_hook <cwd> [PATH]: prints the hook output for a session started in cwd.
run_hook() {
    local cwd=$1
    (cd "$cwd" && env PATH="${2:-$PATH}" "$BASH_BIN" "$HOOK")
}

# expect_text <cwd> <expected text> <label>: the output must be the SessionStart
# JSON carrying the expected text. The command substitution drops the file's
# final newline, so the expected text is given without it.
expect_text() {
    local out got
    out=$(run_hook "$1")
    got=$(jq -er '.hookSpecificOutput | select(.hookEventName == "SessionStart") | .additionalContext' <<< "$out") ||
        fail "$3: output is not SessionStart JSON: $out"
    [[ "$got" == "$2" ]] || fail "$3: got '$got'"
    printf 'PASS: %s\n' "$3"
}

# expect_silent <cwd> <label>: no output and exit 0.
expect_silent() {
    local out status=0
    out=$(run_hook "$1") || status=$?
    [[ $status -eq 0 && -z "$out" ]] || fail "$2: expected no output and exit 0 (status $status): $out"
    printf 'PASS: %s\n' "$2"
}

expect_text "$WORKTREE" "$DOTFILES_TEXT" 'worker worktree gets its assignment file, escaped as JSON'
expect_text "$WORKTREE/env/deep" "$DOTFILES_TEXT" 'a folder inside the worktree names the same worker'
expect_text "$TASK/research" "$RESEARCH_TEXT" 'research folder gets the researcher assignment file'
expect_silent "$TASK" 'the task root (orchestrator) gets nothing'
# The file is named for the agent, worker-<repo>; the bare repo name is no longer read.
mv "$TASK/hooks/worker-dotfiles.md" "$TASK/hooks/dotfiles.md"
expect_silent "$WORKTREE" 'a worker is not handed the old hooks/<repo>.md name'
mv "$TASK/hooks/dotfiles.md" "$TASK/hooks/worker-dotfiles.md"
# The researcher starts in research/, never inside a context clone, so a clone
# (a git repo of its own) takes no assignment.
mkdir -p "$TASK/research/context/clonesrc" && git -C "$TASK/research/context/clonesrc" init -q
expect_silent "$TASK/research/context/clonesrc" 'a context clone gets no assignment (the researcher starts in research/)'

# A worker without an assignment file, and a folder that is neither a worktree
# nor research, get nothing and no error.
mkdir -p "$TASK/other-worktree" && git -C "$TASK/other-worktree" init -q
expect_silent "$TASK/other-worktree" 'a worker with no assignment file gets nothing'
rm "$TASK/hooks/researcher.md"
expect_silent "$TASK/research" 'a missing researcher file gets nothing'
printf '%s\n' "$RESEARCH_TEXT" > "$TASK/hooks/researcher.md"

# Without jq the hook stays silent: a missing tool must not fail the session start.
NOJQ="$TMP_ROOT/nojq"
mkdir -p "$NOJQ"
ln -s "$(command -v git)" "$NOJQ/git"
out=$(run_hook "$WORKTREE" "$NOJQ") || fail 'hook exited non-zero without jq'
[[ -z "$out" ]] || fail "hook printed without jq: $out"
printf 'PASS: without jq the hook prints nothing and exits 0\n'
