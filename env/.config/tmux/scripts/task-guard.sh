#!/usr/bin/env bash
# PreToolUse guard for Claude agents: task-guard.sh worker|researcher, wired in
# task-roles/worker.claude-settings.json and researcher.claude-settings.json.
# A Write, Edit, MultiEdit or NotebookEdit may change only:
#   worker      a file in the worker's worktree, or in its own reports folder,
#               <task-root>/reports/worker-<repo>/.
#   researcher  a file under <task-root>/research/ (its notes), or in its own
#               reports folder, <task-root>/reports/researcher/. Nothing under
#               research/context/: those clones are read-only.
# The agent's folder is CLAUDE_PROJECT_DIR, the folder Claude was launched in,
# not the current directory, which a Bash `cd` can move. A blocked call exits 2
# with the reason on stderr; an allowed one exits 0 with no output, so Claude's
# permission mode still decides. Bash redirects are not covered. Fails closed: an
# unknown mode, missing input or jq, an unknown folder or an unresolvable path
# blocks the call.
set -uo pipefail

block() {
    printf 'task-guard: %s\n' "$1" >&2
    exit 2
}

main() {
    local mode=${1:-} input path project resolved wt name folder d a
    local -a allow=() deny=()
    case "$mode" in
        worker | researcher) ;;
        *) block "unknown guard mode '${mode:-none}'; expected worker or researcher" ;;
    esac
    input=$(cat)
    command -v jq >/dev/null || block 'jq is missing, so the write cannot be checked'
    path=$(jq -r '(.tool_input.file_path // .tool_input.notebook_path) // empty' <<< "$input" 2>/dev/null) || path=
    [[ -n "$path" ]] || block 'the call names no file path'
    [[ "$path" == /* ]] || block "file path must be absolute: $path"
    project=${CLAUDE_PROJECT_DIR:-}
    [[ -n "$project" ]] || block 'CLAUDE_PROJECT_DIR is not set, so the agent folder is unknown'

    if [[ $mode == worker ]]; then
        wt=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || block 'the worker folder is not a git worktree; nothing may be written'
        wt=$(realpath -e "$wt" 2>/dev/null) || block 'the worker folder is not a git worktree; nothing may be written'
        name=${wt##*/}
        allow=("$wt" "${wt%/*}/reports/worker-$name")
    else
        folder=$(realpath -e "$project" 2>/dev/null) || block "the researcher folder does not exist: $project"
        [[ ${folder##*/} == research ]] || block "the researcher must start in <task-root>/research, not $folder"
        allow=("$folder" "${folder%/*}/reports/researcher")
        deny=("$(realpath -m "$folder/context")")
    fi

    resolved=$(realpath -m -- "$path" 2>/dev/null) || block "cannot resolve $path"
    # Trailing slashes keep a sibling such as worker-dotfiles-old from matching.
    for d in "${deny[@]}"; do
        case "$resolved/" in
            "$d"/*) block "$resolved is inside $d, a read-only context clone; the clones take no writes" ;;
        esac
    done
    for a in "${allow[@]}"; do
        case "$resolved/" in
            "$a"/*) return 0 ;;
        esac
    done
    block "$resolved is outside this $mode's writable folders (${allow[*]}); write there, or ask the orchestrator"
}

main "$@"
