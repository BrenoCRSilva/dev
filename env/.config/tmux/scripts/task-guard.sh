#!/usr/bin/env bash
# PreToolUse guard for Claude worker agents (task-roles/worker.claude-settings.json).
# A Write, Edit, MultiEdit or NotebookEdit may change only a file inside the
# worker's worktree or in its own reports folder, <task-root>/reports/worker-<repo>/.
# Any other path exits 2, which blocks the call and shows Claude the reason. An
# allowed call exits 0 with no output, so Claude's permission mode still decides.
# The worker is the folder Claude was launched in (CLAUDE_PROJECT_DIR), not the
# current directory, which a Bash `cd` can move into another worktree; without
# that variable the call is blocked. Bash redirects are not covered. Fails
# closed: when the input, jq or the worktree cannot be read, the call is blocked.
set -uo pipefail

block() {
    printf 'task-guard: %s\n' "$1" >&2
    exit 2
}

main() {
    local input path project wt name reports resolved
    input=$(cat)
    command -v jq >/dev/null || block 'jq is missing, so the write cannot be checked'
    path=$(jq -r '(.tool_input.file_path // .tool_input.notebook_path) // empty' <<< "$input" 2>/dev/null) || path=
    [[ -n "$path" ]] || block 'the call names no file path'
    [[ "$path" == /* ]] || block "file path must be absolute: $path"
    project=${CLAUDE_PROJECT_DIR:-}
    [[ -n "$project" ]] || block 'CLAUDE_PROJECT_DIR is not set, so the worker folder is unknown'
    wt=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || block 'the worker folder is not a git worktree; nothing may be written'
    wt=$(realpath -e "$wt") || block 'the worker folder is not a git worktree; nothing may be written'
    name=${wt##*/}
    reports="${wt%/*}/reports/worker-$name"
    resolved=$(realpath -m -- "$path") || block "cannot resolve $path"
    # The trailing slash keeps a sibling such as worker-dotfiles-old from matching.
    case "$resolved/" in
        "$wt"/* | "$reports"/*) return 0 ;;
    esac
    block "$resolved is outside worker-$name's worktree ($wt) and its reports folder ($reports); write there, or ask the orchestrator"
}

main
