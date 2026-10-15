#!/usr/bin/env bash
# SessionStart hook for repo and researcher agents. Adds the agent's assignment
# file, <task-root>/hooks/<agent>.md, to its context; the orchestrator writes it.
# The agent is named by the session's folder: a worker's worktree
# (<task-root>/<repo>) or the researcher's folder (<task-root>/research). The
# same command serves both providers, so one hook trust covers every agent.
# Prints nothing, and exits 0, when there is no file or no jq.
set -uo pipefail

main() {
    local top agent root file cwd
    cwd=$(pwd -P)
    if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
        agent=${top##*/}
        root=${top%/*}
    elif [[ ${cwd##*/} == research ]]; then
        agent=researcher
        root=${cwd%/*}
    else
        return 0
    fi
    file="$root/hooks/$agent.md"
    [[ -f "$file" ]] && command -v jq >/dev/null || return 0
    jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' < "$file"
}

main
