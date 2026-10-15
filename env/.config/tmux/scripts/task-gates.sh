#!/usr/bin/env bash
# task-gates.sh <worktree> [--base <ref>] [--json] [--list]: runs a task branch's checks
# before the orchestrator merges, and prints one PASS or FAIL line per check. A FAIL
# shows the last 20 lines of that check's output. It never merges, pushes, deploys
# or edits tracked files.
#
# Checks: three built-in ones (clean worktree, branch ahead of --base, no AI trailers
# in base..HEAD), then the repo's gates. The gates are the `name: command` lines of
# <worktree>/.task-gates, run from the worktree root in order. Without that file the
# defaults that match the repo are used: shellcheck on the *.sh changed since base,
# package.json lint/test/typecheck (npm, pnpm, yarn or bun by lockfile), a Makefile
# test target, pytest when tests/ and pyproject.toml exist, and go test ./...
# --base defaults to origin/HEAD, else main, else master. --list prints the gates
# without running them. --json writes <task-root>/reports/orchestrator/gates-<repo>-<sha>.json
# (one per head commit); the orchestrator's reports folder is written only by this script.
#
# Exit: 0 all pass; 1 any check failed (failures win over no gates); 2 usage error, a
# bad .task-gates line, or a report that could not be written; 3 no gates declared or
# detected (the built-in checks still ran).
set -uo pipefail

TRAILER_RE='^[[:space:]]*co-authored-by:|generated with .*(claude|anthropic)|^[[:space:]]*(assisted|generated|authored)-by:.*(claude|anthropic|openai|codex|gpt|gemini|copilot)|🤖'
GATE_NAMES=() GATE_CMDS=() DETECTED=()
NAMES=() LABELS=() CODES=() MS=() OUTS=()
SOURCE=none

usage() {
    cat >&2 <<'EOF'
usage: task-gates.sh <worktree> [--base <ref>] [--json] [--list]
EOF
    exit 2
}

# add_gate <name> <command>: queues a gate to run after the built-in checks.
add_gate() {
    GATE_NAMES+=("$1")
    GATE_CMDS+=("$2")
}

# read_declared: the gates of <worktree>/.task-gates. Blank lines and # comments are skipped.
read_declared() {
    local line name cmd
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *:* ]] || { echo "task-gates: .task-gates line needs 'name: command': $line" >&2; exit 2; }
        name=${line%%:*}
        cmd=${line#*:}
        name=${name//[[:space:]]/}
        cmd=${cmd#"${cmd%%[![:space:]]*}"}
        [[ $name =~ ^[A-Za-z0-9._-]+$ && -n $cmd ]] || { echo "task-gates: bad .task-gates line: $line" >&2; exit 2; }
        add_gate "$name" "$cmd"
    done < "$top/.task-gates"
}

# detect_gates: the default gates that apply to this repo; each one found is listed in DETECTED.
detect_gates() {
    local pm script files
    local -a sh_files=()
    mapfile -t sh_files < <(git -C "$top" diff --name-only --diff-filter=ACMR "$base...HEAD" -- '*.sh')
    if (( ${#sh_files[@]} > 0 )); then
        printf -v files ' %q' "${sh_files[@]}"
        add_gate shellcheck "shellcheck -x$files"
        DETECTED+=("shellcheck (${#sh_files[@]} files)")
    fi
    if [[ -f $top/package.json ]] && jq -e . "$top/package.json" >/dev/null 2>&1; then
        pm=npm
        [[ -f $top/pnpm-lock.yaml ]] && pm=pnpm
        [[ -f $top/yarn.lock ]] && pm=yarn
        [[ -f $top/bun.lockb || -f $top/bun.lock ]] && pm=bun
        for script in lint test typecheck; do
            if jq -e --arg s "$script" '.scripts[$s]' "$top/package.json" >/dev/null 2>&1; then
                add_gate "package:$script" "$pm run $script"
                DETECTED+=("package:$script ($pm)")
            fi
        done
    fi
    if [[ -f $top/Makefile ]] && grep -qE '^test:' "$top/Makefile"; then
        add_gate make:test 'make test'
        DETECTED+=(make:test)
    fi
    if [[ -d $top/tests && -f $top/pyproject.toml ]]; then
        add_gate pytest pytest
        DETECTED+=(pytest)
    fi
    if [[ -f $top/go.mod ]]; then
        add_gate go-test 'go test ./...'
        DETECTED+=('go test ./...')
    fi
}

# record <name> <label> <exit> <ms> <output file>: keeps the check and prints its line.
record() {
    local secs="$(( $4 / 1000 )).$(( ($4 % 1000) / 100 ))"
    NAMES+=("$1") LABELS+=("$2") CODES+=("$3") MS+=("$4") OUTS+=("$5")
    if (( $3 == 0 )); then
        printf 'PASS %s (exit 0, %ss)\n' "$1" "$secs"
    else
        printf 'FAIL %s (exit %s, %ss)\n' "$1" "$3" "$secs"
        tail -n 20 "$5" | sed 's/^/    /'
    fi
}

# run_builtin <name> <function>: runs a built-in check in the worktree.
run_builtin() {
    local out start rc
    out=$(mktemp "$tmp_dir/out.XXXXXX")
    start=$(date +%s%N)
    (cd "$top" && "$2") > "$out" 2>&1
    rc=$?
    record "$1" 'built-in' "$rc" "$(( ($(date +%s%N) - start) / 1000000 ))" "$out"
}

# run_gate <name> <command>: runs a declared or detected gate from the worktree root.
run_gate() {
    local out start rc
    out=$(mktemp "$tmp_dir/out.XXXXXX")
    start=$(date +%s%N)
    (cd "$top" && timeout "${TASK_GATE_TIMEOUT:-1800}" bash -c "$2") > "$out" 2>&1
    rc=$?
    record "$1" "$2" "$rc" "$(( ($(date +%s%N) - start) / 1000000 ))" "$out"
}

# shellcheck disable=SC2329 # run_builtin calls these by name
check_clean() {
    local dirty
    dirty=$(git status --porcelain)
    [[ -z $dirty ]] || { printf '%s\n' "$dirty"; return 1; }
}

# shellcheck disable=SC2329 # run_builtin calls these by name
check_ahead() {
    local n
    n=$(git rev-list --count "$base..HEAD") || return 1
    (( n > 0 )) || { printf 'no commits in %s..HEAD\n' "$base"; return 1; }
    printf '%s commit(s) ahead of %s\n' "$n" "$base"
}

# shellcheck disable=SC2329 # run_builtin calls these by name
check_trailers() {
    local c line bad=0
    for c in $(git rev-list "$base..HEAD"); do
        while IFS= read -r line; do
            printf '%s: %s\n' "$(git rev-parse --short "$c")" "$line"
            bad=1
        done < <(git log -1 --format=%B "$c" | grep -iE "$TRAILER_RE")
    done
    return "$bad"
}

# write_json <result> <exit>: the report for this run, one file per head commit.
write_json() {
    local dir="$root/reports/orchestrator" file checks i
    file="$dir/gates-$repo-$sha.json"
    mkdir -p "$dir" || return 1
    checks=$(for i in "${!NAMES[@]}"; do
        jq -nc --arg name "${NAMES[i]}" --arg command "${LABELS[i]}" --argjson exit "${CODES[i]}" \
            --argjson duration_ms "${MS[i]}" '{name: $name, command: $command, exit: $exit, duration_ms: $duration_ms}'
    done | jq -s '.') || return 1
    jq -n --arg repo "$repo" --arg worktree "$top" --arg head "$head" --arg base "$base" --arg base_sha "$base_sha" \
        --arg source "$SOURCE" --arg result "$1" --argjson exit "$2" --arg generated "$(date -Is)" \
        --argjson checks "$checks" \
        '{repo: $repo, worktree: $worktree, head_sha: $head, base: $base, base_sha: $base_sha, source: $source,
          generated_at: $generated, result: $result, exit: $exit, checks: $checks}' > "$file" || return 1
    printf 'report: %s\n' "$file"
}

main() {
    local worktree='' base_arg='' json=no list=no arg
    while (( $# )); do
        arg=$1
        case $arg in
            --base) (( $# >= 2 )) || usage; base_arg=$2; shift 2; continue ;;
            --json) json=yes ;;
            --list) list=yes ;;
            -h | --help) usage ;;
            -*) usage ;;
            *) [[ -z $worktree ]] || usage; worktree=$arg ;;
        esac
        shift
    done
    [[ -n $worktree ]] || usage

    top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) ||
        { echo "task-gates: not a git worktree: $worktree" >&2; exit 2; }
    top=$(realpath -e "$top")
    repo=${top##*/}
    root=${top%/*}
    head=$(git -C "$top" rev-parse HEAD) || exit 2
    sha=$(git -C "$top" rev-parse --short=7 HEAD)

    if [[ -n $base_arg ]]; then
        base=$base_arg
    else
        base=$(git -C "$top" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || base=''
        base=${base#refs/remotes/}
        if [[ -z $base ]]; then
            if git -C "$top" rev-parse --verify -q main >/dev/null; then base=main
            elif git -C "$top" rev-parse --verify -q master >/dev/null; then base=master
            else echo "task-gates: no --base given and no origin/HEAD, main or master" >&2; exit 2; fi
        fi
    fi
    base_sha=$(git -C "$top" rev-parse --verify -q "$base^{commit}") ||
        { echo "task-gates: base does not name a commit: $base" >&2; exit 2; }

    if [[ -f $top/.task-gates ]]; then
        SOURCE=.task-gates
        read_declared
    else
        detect_gates
        (( ${#GATE_NAMES[@]} == 0 )) || SOURCE=detected
    fi

    if [[ $list == yes ]]; then
        for i in "${!GATE_NAMES[@]}"; do printf '%s: %s\n' "${GATE_NAMES[i]}" "${GATE_CMDS[i]}"; done
        (( ${#GATE_NAMES[@]} > 0 )) || { echo 'no gates declared'; exit 3; }
        exit 0
    fi

    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT
    case $SOURCE in
        .task-gates) echo "gates: ${#GATE_NAMES[@]} from .task-gates; base $base" ;;
        detected) echo "gates: no .task-gates; detected ${DETECTED[*]}; base $base" ;;
        none) echo "gates: no .task-gates and no defaults detected; base $base" ;;
    esac

    run_builtin clean-tree check_clean
    run_builtin ahead-of-base check_ahead
    run_builtin no-ai-trailers check_trailers
    for i in "${!GATE_NAMES[@]}"; do run_gate "${GATE_NAMES[i]}" "${GATE_CMDS[i]}"; done

    local failed=0 code result
    for i in "${!CODES[@]}"; do (( CODES[i] == 0 )) || failed=$(( failed + 1 )); done
    if (( failed > 0 )); then code=1; result=fail
    elif (( ${#GATE_NAMES[@]} == 0 )); then code=3; result=no-gates
    else code=0; result=pass; fi

    if (( failed > 0 )); then echo "task-gates: $result ($failed of ${#CODES[@]} checks failed)"
    elif (( code == 3 )); then echo 'task-gates: no gates declared (the built-in checks passed)'
    else echo "task-gates: $result (${#CODES[@]} checks)"; fi

    if [[ $json == yes ]]; then
        write_json "$result" "$code" || { echo "task-gates: could not write the report under $root/reports/orchestrator" >&2; exit 2; }
    fi
    exit "$code"
}

main "$@"
