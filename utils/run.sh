#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
filter=""
dry="0"

while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--dry" ]]; then
        dry="1"
    else
        filter="$1"
    fi
    shift
done

log() {
    if [[ "$dry" == "1" ]]; then
        echo "[DRY_RUN]: $*"
    else
        echo "$*"
    fi
}

execute() {
    log "execute: $*"
    if [[ "$dry" == "1" ]]; then
        return
    fi
    "$@"
}

log "run: filter=$filter"

shopt -s nullglob
scripts=("$repo_root"/runs/*.sh)

for script in "${scripts[@]}"; do
    base="$(basename "$script")"

    if [[ -n "$filter" && "$base" != "$filter" && "$base" != "$filter.sh" ]]; then
        log "filtered: $filter -- $base"
        continue
    fi

    log "running script: $base"
    execute "$script"
done
