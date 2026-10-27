#!/usr/bin/env bash
# task-sessionizer.sh contexts (C7) and the background codegraph index of context
# clones: a temp task with two context repos, a fake codegraph that records its calls
# and can be held. Checks the table and --json rows (sha, behind, indexed), init on
# clone, sync after a fast-forward, the indexing state, and that the index log does
# not count as custom data at close; a stale lock taken by one caller only, and drop
# stopping a running job and removing its log and lock. Writes only inside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SESSIONIZER="$ROOT/env/.config/tmux/scripts/task-sessionizer.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
HOME="$TMP_ROOT/home"
TASKS_DIR="$TMP_ROOT/tasks"
BIN="$TMP_ROOT/bin"
HOLD="$TMP_ROOT/hold"
export HOME TASKS_DIR HOLD
mkdir -p "$HOME/Projects" "$TASKS_DIR/t/research" "$BIN"
PATH="$BIN:/usr/bin:/bin"
export PATH
printf '# t\n' > "$TASKS_DIR/t/AGENTS.md"

# Fake codegraph: logs its args and cwd, waits while $HOLD exists, makes the index.
cat > "$BIN/codegraph" <<'SH'
#!/bin/sh
echo "codegraph $* in $(pwd)"
while [ -e "$HOLD" ]; do sleep 0.1; done
mkdir -p .codegraph
SH
printf '#!/bin/sh\nexit 1\n' > "$BIN/tmux"
chmod +x "$BIN/codegraph" "$BIN/tmux"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
make_repo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.name Fixture
    git -C "$1" config user.email fixture@example.invalid
    printf '%s\n' "$1" > "$1/README.md"
    git -C "$1" add README.md
    git -C "$1" commit -qm init
}
commit() { printf '%s\n' "$2" >> "$1/README.md"; git -C "$1" commit -qam "$2"; }
# wait_idle <name>: until the clone's index lock is gone (at most 10 s).
wait_idle() {
    for _ in $(seq 100); do
        [[ -e "$TASKS_DIR/t/research/context/.codegraph-$1.lock" ]] || return 0
        sleep 0.1
    done
    fail "index of $1 still running"
}

alpha="$HOME/Projects/alpha"
beta="$HOME/Projects/beta"
make_repo "$alpha"
make_repo "$beta"
printf 'alpha\t%s\nbeta\t%s\n' "$alpha" "$beta" > "$TASKS_DIR/t/.task-context.tsv"
ctx="$TASKS_DIR/t/research/context"

# Missing clones: rows show "-" and no index.
rows=$("$SESSIONIZER" contexts t --json)
python3 -I - "$rows" "$alpha" <<'PY' || fail "rows without clones: $rows"
import json, sys
rows = json.loads(sys.argv[1])
assert [r["name"] for r in rows] == ["alpha", "beta"], rows
assert rows[0] == {"name": "alpha", "canonical": sys.argv[2], "sha": "-", "behind": "-", "indexed": "no"}, rows[0]
PY

# refresh recreates both clones; each gets codegraph init -y in the background.
"$SESSIONIZER" refresh t > /dev/null
wait_idle alpha
wait_idle beta
for n in alpha beta; do
    grep -q "codegraph init -y in $ctx/$n" "$ctx/.codegraph-$n.log" ||
        fail "no init for $n: $(cat "$ctx/.codegraph-$n.log")"
    [[ -d "$ctx/$n/.codegraph" ]] || fail "$n has no index"
    [[ -z $(git -C "$ctx/$n" status --porcelain --untracked-files=all) ]] || fail "the index makes $n look dirty"
done

# beta's canonical moves on by two commits: beta is behind 2, alpha 0, both indexed.
commit "$beta" one
commit "$beta" two
rows=$("$SESSIONIZER" contexts t --json)
python3 -I - "$rows" "$(git -C "$ctx/beta" rev-parse --short HEAD)" <<'PY' || fail "rows after canonical commits: $rows"
import json, sys
a, b = json.loads(sys.argv[1])
assert (a["behind"], a["indexed"]) == ("0", "yes"), a
assert (b["sha"], b["behind"], b["indexed"]) == (sys.argv[2], "2", "yes"), b
PY
table=$("$SESSIONIZER" contexts t)
[[ $(head -1 <<< "$table") == NAME*CANONICAL*SHA*BEHIND*INDEXED ]] || fail "table header: $table"
grep -Eq "^beta +$beta +[0-9a-f]+ +2 +yes$" <<< "$table" || fail "table row for beta: $table"

# Refresh with the fake held: beta fast-forwards and syncs in the background, so it
# shows indexing; alpha does not move and runs nothing.
touch "$HOLD"
"$SESSIONIZER" refresh t > /dev/null
[[ $("$SESSIONIZER" contexts t --json | python3 -Ic 'import json,sys; print(json.load(sys.stdin)[1]["indexed"])') == indexing ]] ||
    fail 'beta does not show indexing during its sync'
rm -f "$HOLD"
wait_idle beta
grep -q "codegraph sync in $ctx/beta" "$ctx/.codegraph-beta.log" || fail "no sync after the fast-forward: $(cat "$ctx/.codegraph-beta.log")"
grep -q sync "$ctx/.codegraph-alpha.log" && fail 'alpha synced without moving'
[[ $("$SESSIONIZER" contexts t --json | python3 -Ic 'import json,sys; r=json.load(sys.stdin)[1]; print(r["behind"], r["indexed"])') == '0 yes' ]] ||
    fail 'beta is not up to date and indexed after refresh'

# A stale lock (dead pid) does not show as indexing.
mkdir "$ctx/.codegraph-alpha.lock"
echo 999999 > "$ctx/.codegraph-alpha.lock/pid"
[[ $("$SESSIONIZER" contexts t --json | python3 -Ic 'import json,sys; print(json.load(sys.stdin)[0]["indexed"])') == yes ]] ||
    fail 'a stale lock shows as indexing'

# Close checks: the logs and locks are generated, not custom data.
issues=$(bash -c 'source <(sed -n "/^context_clone_issues()/,/^}/p" "$1"); TASKS_DIR=$2 context_clone_issues t' _ "$SESSIONIZER" "$TASKS_DIR")
[[ -z $issues ]] || fail "close reports generated index files: $issues"

# run_fns <script>: runs bash code with the sessionizer's index and drop functions.
run_fns() {
    bash -c 'source <(grep "^context_clone_dir()" "$1"; sed -n "/^index_context()/,/^}/p;/^index_running()/,/^}/p;/^drop_context_clone()/,/^}/p" "$1")
        eval "$3"' _ "$SESSIONIZER" "$TASKS_DIR" "TASKS_DIR=$TASKS_DIR; $1"
}
# wait_pid <name>: prints the pid of the clone's running index job (at most 10 s).
wait_pid() {
    for _ in $(seq 100); do
        cat "$ctx/.codegraph-$1.lock/pid" 2>/dev/null && return 0
        sleep 0.1
    done
    fail "index of $1 wrote no pid"
}

# Stale lock race: this caller saw alpha's lock stale, then another caller took a fresh
# one. The fresh lock is kept (put back after the rename) and nothing runs.
rm -rf "$ctx/.codegraph-alpha.lock"
mkdir "$ctx/.codegraph-alpha.lock"
touch "$ctx/.codegraph-alpha.lock/mark"
before=$(wc -l < "$ctx/.codegraph-alpha.log")
run_fns 'eval "real_$(declare -f index_running)"
    index_running() { [[ -e $HOLD.seen ]] && { real_index_running "$@"; return; }; touch "$HOLD.seen"; return 1; }
    index_context t alpha sync'
[[ -e "$ctx/.codegraph-alpha.lock/mark" ]] || fail 'the fresh lock of another caller was removed'
compgen -G "$ctx/.codegraph-alpha.lock.stale.*" > /dev/null && fail 'a renamed lock was left behind'
sleep 0.3
[[ $(wc -l < "$ctx/.codegraph-alpha.log") == "$before" ]] || fail "a second job ran on alpha: $(cat "$ctx/.codegraph-alpha.log")"
# A stale lock (dead pid) is taken over and the job runs.
echo 999999 > "$ctx/.codegraph-alpha.lock/pid"
run_fns 'index_context t alpha sync'
wait_idle alpha
grep -q "codegraph sync in $ctx/alpha" "$ctx/.codegraph-alpha.log" || fail "no sync after a stale lock: $(cat "$ctx/.codegraph-alpha.log")"

# drop with the clone already gone and an index job running: the job is stopped and
# the log and lock go too.
touch "$HOLD"
run_fns 'index_context t beta sync'
pid=$(wait_pid beta)
rm -rf "$ctx/beta"
run_fns 'drop_context_clone t beta'
rm -f "$HOLD"
kill -0 "$pid" 2>/dev/null && fail 'drop left the index job running'
compgen -G "$ctx/.codegraph-beta*" > /dev/null && fail "drop left index files: $(ls -a "$ctx")"
# drop with the clone there removes it and the now empty research/context.
run_fns 'drop_context_clone t alpha'
[[ -e $ctx ]] && fail "drop left research/context: $(ls -a "$ctx")"

"$SESSIONIZER" contexts nosuch 2>/dev/null && fail 'contexts accepted a missing task'
"$SESSIONIZER" contexts t --bad 2>/dev/null && fail 'contexts accepted a bad flag'
printf 'PASS: contexts rows (table and --json), init on clone, sync on fast-forward, indexing state, stale lock, close ignores index logs, stale lock race, drop stops the job and removes log and lock\n'
