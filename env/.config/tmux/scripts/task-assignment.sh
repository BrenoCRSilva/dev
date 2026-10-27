#!/usr/bin/env bash
# SessionStart hook for worker and researcher agents. Starts the codegraph index of
# the agent's folder in the background, then adds two things to its context: the
# agent's assignment file, <task-root>/hooks/<agent>.md (the orchestrator writes
# it), and one codegraph status line. The agent is named by the session's folder:
# a worker's worktree (<task-root>/<repo>) is worker-<repo>, the researcher's folder
# (<task-root>/research) is researcher, and its clones under research/context/ are
# indexed too. The same command serves both providers, so one hook trust covers
# every agent. Prints nothing, and exits 0, when there is no file and no codegraph
# line, or when there is no jq. Indexing never delays the session: the work runs in
# a detached batch (--index-batch), and the hook returns at once.
set -uo pipefail

BUILDING='codegraph: index building in background; use grep until codegraph tools return results'
PRESENT='codegraph: index present'
CODEGRAPH_LINE=''

# acquire_lock <dir>: takes the batch lock by mkdir. A lock is live while the pid
# its batch wrote runs. A lock with no pid yet is live for 30 seconds, the time a
# batch needs to start. A stale lock is renamed away first, so only one hook reclaims it.
acquire_lock() {
    local lock=$1 pid
    mkdir "$lock" 2>/dev/null && return 0
    if pid=$(cat "$lock/pid" 2>/dev/null); then
        kill -0 "$pid" 2>/dev/null && return 1
    elif (( $(date +%s) - $(stat -c %Y "$lock") < 30 )); then
        return 1
    fi
    mv "$lock" "$lock.stale.$$" 2>/dev/null || return 1
    rm -rf "$lock.stale.$$"
    mkdir "$lock" 2>/dev/null
}

# index_start <reports> <folder>...: starts one detached batch for the folders that
# have no .codegraph/ yet, and sets CODEGRAPH_LINE. The batch's log and lock sit in
# the agent's reports folder: outside the worktree and the clones, and never tracked.
index_start() {
    local reports=$1 lock log folder
    local -a pending=()
    shift
    lock="$reports/codegraph-index.lock"
    log="$reports/codegraph-index.log"
    for folder in "$@"; do [[ -e "$folder/.codegraph" ]] || pending+=("$folder"); done
    if ! acquire_lock "$lock"; then CODEGRAPH_LINE=$BUILDING; return 0; fi
    if (( ${#pending[@]} == 0 )); then
        rmdir "$lock"
        CODEGRAPH_LINE=$PRESENT
        return 0
    fi
    # setsid -f detaches the batch from the session. The batch writes its own pid, so
    # the lock is correct however setsid forks. Its output goes to the log, not the hook.
    setsid -f "$(realpath "${BASH_SOURCE[0]}")" --index-batch "$lock" "${pending[@]}" </dev/null >> "$log" 2>&1
    CODEGRAPH_LINE=$BUILDING
}

# index_batch <lock> <folder>...: the detached job. Runs codegraph init one folder at a
# time, skipping any folder that got its index meanwhile, and removes the lock on exit.
# CODEGRAPH_NO_WATCH is unset on purpose: init installs git hooks into the shared .git
# when the watcher is off.
index_batch() {
    INDEX_LOCK=$1
    shift
    trap 'rm -rf -- "$INDEX_LOCK"' EXIT
    echo $$ > "$INDEX_LOCK/pid"
    local folder
    for folder in "$@"; do
        [[ -e "$folder/.codegraph" ]] && continue
        printf '%s init %s\n' "$(date -Is)" "$folder"
        (cd "$folder" && env -u CODEGRAPH_NO_WATCH CODEGRAPH_TELEMETRY=0 codegraph init -y < /dev/null) ||
            printf '%s init failed in %s\n' "$(date -Is)" "$folder"
    done
}

main() {
    local top agent root file cwd reports text="" d
    local -a folders=()
    cwd=$(pwd -P)
    if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
        agent=worker-${top##*/}
        root=${top%/*}
        # A context clone belongs to the researcher, so no worker session indexes it.
        [[ ${root##*/} == context ]] || folders=("$top")
    elif [[ ${cwd##*/} == research ]]; then
        agent=researcher
        root=${cwd%/*}
        # Fallback only: the sessionizer indexes each clone when it makes or refreshes
        # it, and a clone it is indexing now (its lock exists) is skipped.
        for d in "$cwd"/context/*/; do
            d=${d%/}
            [[ -e "$cwd/context/.codegraph-${d##*/}.lock" ]] && continue
            [[ -d $d && $(git -C "$d" rev-parse --show-toplevel 2>/dev/null) == "$(realpath -e "$d")" ]] &&
                folders+=("$d")
        done
    else
        return 0
    fi
    reports="$root/reports/$agent"
    if (( ${#folders[@]} > 0 )) && command -v codegraph >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1 &&
        mkdir -p "$reports" 2>/dev/null; then
        index_start "$reports" "${folders[@]}"
    fi
    file="$root/hooks/$agent.md"
    [[ -f "$file" ]] && text=$(<"$file")
    if [[ -n $CODEGRAPH_LINE ]]; then text+=${text:+$'\n\n'}$CODEGRAPH_LINE; fi
    [[ -n $text ]] && command -v jq >/dev/null || return 0
    jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' <<< "$text"
}

if [[ ${1:-} == --index-batch ]]; then
    shift
    index_batch "$@"
else
    main
fi
