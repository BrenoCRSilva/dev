#!/usr/bin/env bash
# task-assignment.sh starts the codegraph index of the agent's folder in a detached
# batch and adds one status line to the context. A stub codegraph records each init
# (folder and environment), makes .codegraph/ and sleeps STUB_SLEEP seconds. Covers
# a missing and a present index, concurrent hooks, no codegraph, a researcher with
# two clones (indexed in order, a plain folder skipped), a context clone, a stale
# lock, and a hook that returns before the stub finishes. Writes only inside a
# temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/env/.config/tmux/scripts/task-assignment.sh"
BASH_BIN=$(command -v bash)
TMP_ROOT=$(realpath "$(mktemp -d)")
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TASK="$TMP_ROOT/tasks/fixture"
CALLS="$TMP_ROOT/calls.log"
STUB_BIN="$TMP_ROOT/stub-bin"
export CALLS
# CODEGRAPH_NO_WATCH is set on purpose: the hook must not pass it on to init.
export CODEGRAPH_NO_WATCH=1
mkdir -p "$STUB_BIN" "$TMP_ROOT/home" "$TASK/hooks" "$TASK/research/context"
cat > "$STUB_BIN/codegraph" <<'STUB'
#!/bin/sh
# Stub: init records the folder and environment, makes .codegraph/ and sleeps.
[ "$1" = init ] || exit 0
d=$(pwd -P)
printf 'init %s telemetry=%s nowatch=%s\n' "$d" "${CODEGRAPH_TELEMETRY-unset}" "${CODEGRAPH_NO_WATCH-unset}" >> "$CALLS"
sleep "${STUB_SLEEP:-0}"
mkdir .codegraph
printf 'done %s\n' "$d" >> "$CALLS"
STUB
chmod +x "$STUB_BIN/codegraph"

BUILDING='codegraph: index building in background; use grep until codegraph tools return results'
PRESENT='codegraph: index present'

# hook <cwd> [stub sleep seconds]: runs the hook as a session started in cwd, with the stub on PATH.
hook() {
    (cd "$1" && env HOME="$TMP_ROOT/home" PATH="$STUB_BIN:/usr/bin:/bin" STUB_SLEEP="${2:-0}" "$BASH_BIN" "$HOOK")
}
# hook_nocg <cwd>: the same without codegraph on PATH.
hook_nocg() {
    (cd "$1" && env HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" "$BASH_BIN" "$HOOK")
}
# context <output>: the additionalContext text of a hook's JSON output.
context() { jq -r '.hookSpecificOutput.additionalContext' <<< "$1"; }
# new_worker <name>: a worktree <task>/<name> with an assignment file for worker-<name>.
new_worker() {
    mkdir -p "$TASK/$1" && git -C "$TASK/$1" init -q
    printf 'assignment for worker-%s\n' "$1" > "$TASK/hooks/worker-$1.md"
}
reset_calls() { : > "$CALLS"; }
init_count() { grep -c '^init ' "$CALLS" || true; }
elapsed_ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
# wait_idle <lock> <label>: waits until the batch removes its lock.
wait_idle() {
    for _ in $(seq 300); do [[ -e "$1" ]] || return 0; sleep 0.1; done
    fail "$2: the batch still holds $1"
}

[[ -z "$(PATH=/usr/bin:/bin command -v codegraph || true)" ]] || fail 'precondition: codegraph is on /usr/bin:/bin'

# A missing index: the hook returns at once, one batch runs init, and the index appears.
new_worker dotfiles
WT="$TASK/dotfiles"
LOCK="$TASK/reports/worker-dotfiles/codegraph-index.lock"
reset_calls
start=$(date +%s%N)
out=$(hook "$WT" 2)
ms=$(elapsed_ms "$start")
(( ms < 1000 )) || fail "the hook took ${ms}ms while the stub sleeps 2s; it must return at once"
[[ "$(context "$out")" == $'assignment for worker-dotfiles\n\n'"$BUILDING" ]] ||
    fail "missing index: unexpected context: $(context "$out")"
printf 'PASS: missing index: the hook returns in %sms with the assignment and the building line\n' "$ms"
wait_idle "$LOCK" 'missing index'
[[ $(init_count) == 1 ]] || fail "missing index: expected one init, got: $(cat "$CALLS")"
grep -qx "init $WT telemetry=0 nowatch=unset" "$CALLS" || fail "missing index: init environment is wrong: $(cat "$CALLS")"
[[ -d "$WT/.codegraph" ]] || fail 'missing index: no .codegraph was made'
[[ -s "$TASK/reports/worker-dotfiles/codegraph-index.log" ]] || fail 'missing index: the batch log is empty'
printf 'PASS: missing index: one init, telemetry off, CODEGRAPH_NO_WATCH unset, index made, lock removed\n'

# A present index: the status line says so, and no init starts.
new_worker present
mkdir "$TASK/present/.codegraph"
reset_calls
out=$(hook "$TASK/present" 0)
[[ "$(context "$out")" == $'assignment for worker-present\n\n'"$PRESENT" ]] || fail "present index: unexpected context: $(context "$out")"
sleep 0.3
[[ ! -s "$CALLS" ]] || fail "present index: init ran: $(cat "$CALLS")"
[[ ! -e "$TASK/reports/worker-present/codegraph-index.lock" ]] || fail 'present index: a lock was left behind'
printf 'PASS: present index: the status line says present and no init starts\n'

# Concurrent hooks for one folder: one init, and every hook says building. The
# first hook's batch must have written its pid before the others arrive, so they
# meet a live lock rather than one still being created.
new_worker race
RACE_LOCK="$TASK/reports/worker-race/codegraph-index.lock"
reset_calls
hook "$TASK/race" 2 > "$TMP_ROOT/race-0.out"
for _ in $(seq 100); do [[ -s "$RACE_LOCK/pid" ]] && break; sleep 0.05; done
[[ -s "$RACE_LOCK/pid" ]] || fail 'concurrent hooks: the first batch wrote no pid'
for n in 1 2 3; do hook "$TASK/race" 2 > "$TMP_ROOT/race-$n.out" & done
wait
wait_idle "$RACE_LOCK" 'concurrent hooks'
[[ $(init_count) == 1 ]] || fail "concurrent hooks: expected one init, got $(init_count): $(cat "$CALLS")"
for n in 0 1 2 3; do
    [[ "$(context "$(cat "$TMP_ROOT/race-$n.out")")" == *"$BUILDING" ]] || fail "concurrent hooks: hook $n did not say building"
done
printf 'PASS: concurrent hooks: one init and every hook reports building\n'

# A stale lock (its pid is gone) is reclaimed, so the index still gets built.
new_worker stale
dead=$(sh -c 'echo $$')
mkdir -p "$TASK/reports/worker-stale/codegraph-index.lock"
echo "$dead" > "$TASK/reports/worker-stale/codegraph-index.lock/pid"
reset_calls
out=$(hook "$TASK/stale" 0)
[[ "$(context "$out")" == *"$BUILDING" ]] || fail "stale lock: unexpected context: $(context "$out")"
wait_idle "$TASK/reports/worker-stale/codegraph-index.lock" 'stale lock'
[[ $(init_count) == 1 ]] || fail "stale lock: expected one init, got: $(cat "$CALLS")"
printf 'PASS: a stale lock is reclaimed and one init runs\n'

# No codegraph: the assignment still arrives, with no codegraph line, nothing started.
new_worker plain
reset_calls
out=$(hook_nocg "$TASK/plain")
[[ "$(context "$out")" == 'assignment for worker-plain' ]] || fail "no codegraph: unexpected context: $(context "$out")"
[[ ! -e "$TASK/plain/.codegraph" && ! -d "$TASK/reports/worker-plain" ]] || fail 'no codegraph: something was started or written'
printf 'PASS: no codegraph: the assignment only, nothing started or written\n'

# The researcher: two clones are indexed one after the other; a plain folder is skipped.
RES="$TASK/research"
printf 'researcher assignment\n' > "$TASK/hooks/researcher.md"
mkdir -p "$RES/context/plain"
for clone in alpha beta; do git -C "$RES/context" init -q "$clone"; done
reset_calls
out=$(hook "$RES" 1)
[[ "$(context "$out")" == $'researcher assignment\n\n'"$BUILDING" ]] || fail "researcher: unexpected context: $(context "$out")"
wait_idle "$TASK/reports/researcher/codegraph-index.lock" 'researcher'
[[ $(init_count) == 2 ]] || fail "researcher: expected two inits, got: $(cat "$CALLS")"
alpha_done=$(grep -n "^done $RES/context/alpha\$" "$CALLS" | cut -d: -f1)
beta_init=$(grep -n "^init $RES/context/beta " "$CALLS" | cut -d: -f1)
[[ -n "$alpha_done" && -n "$beta_init" ]] || fail "researcher: missing alpha done or beta init: $(cat "$CALLS")"
(( alpha_done < beta_init )) || fail "researcher: beta started before alpha finished: $(cat "$CALLS")"
[[ -d "$RES/context/alpha/.codegraph" && -d "$RES/context/beta/.codegraph" ]] || fail 'researcher: a clone has no index'
[[ ! -e "$RES/context/plain/.codegraph" ]] || fail 'researcher: a plain folder was indexed'
printf 'PASS: researcher: both clones indexed in order, the plain folder skipped\n'

# Indexed clones: the researcher gets the present line and no init.
reset_calls
out=$(hook "$RES" 0)
[[ "$(context "$out")" == $'researcher assignment\n\n'"$PRESENT" ]] || fail "researcher present: unexpected context: $(context "$out")"
sleep 0.3
[[ ! -s "$CALLS" ]] || fail "researcher present: init ran: $(cat "$CALLS")"
printf 'PASS: researcher with indexed clones: present line, no init\n'

# A context clone is the researcher's: a worker session in one starts nothing.
git -C "$RES/context" init -q gamma
reset_calls
out=$(hook "$RES/context/gamma" 0)
[[ -z "$out" ]] || fail "context clone: a worker session got output: $out"
sleep 0.3
[[ ! -s "$CALLS" && ! -d "$TASK/reports/worker-gamma" ]] || fail 'context clone: a worker session indexed or wrote a report folder'
printf 'PASS: a context clone in a worker session starts no index\n'

echo 'PASS: task-codegraph-index fixture'
