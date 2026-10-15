#!/usr/bin/env bash
# task-gates.sh: declared gates (pass, fail with the last 20 lines, timeout), the
# default gates when .task-gates is absent (listed with --list, not run), a dirty
# tree (ignored files pass), an empty branch, the AI trailer check (base..HEAD only),
# --json reports, and exit codes 2 and 3. Repos are built in a temporary task folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GATES="$ROOT/env/.config/tmux/scripts/task-gates.sh"
TMP_ROOT=$(realpath "$(mktemp -d)")
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

TASK="$TMP_ROOT/tasks/fixture"
mkdir -p "$TASK"
GIT=(git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false)

# make_repo <name>: <task>/<name> on main (a .gitignore that ignores *.tmp, and a README)
# with branch feature one commit ahead (feature.txt, not a shell file).
make_repo() {
    local dir="$TASK/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    printf '*.tmp\n' > "$dir/.gitignore"
    printf 'readme\n' > "$dir/README.md"
    "${GIT[@]}" -C "$dir" add -A
    "${GIT[@]}" -C "$dir" commit -q -m base
    git -C "$dir" checkout -q -b feature
    printf 'feature\n' > "$dir/feature.txt"
    "${GIT[@]}" -C "$dir" add -A
    "${GIT[@]}" -C "$dir" commit -q -m feature
}

# commit_in <name> <subject> [trailer line]: one more commit on the repo's current branch.
commit_in() {
    local dir="$TASK/$1" n
    n=$(date +%s%N)
    printf '%s\n' "$n" >> "$dir/log.txt"
    "${GIT[@]}" -C "$dir" add -A
    if [[ -n ${3:-} ]]; then
        "${GIT[@]}" -C "$dir" commit -q -m "$2" -m "$3"
    else
        "${GIT[@]}" -C "$dir" commit -q -m "$2"
    fi
}

# run_gates <name> [args]: runs task-gates.sh on the repo; sets OUT and RC.
run_gates() {
    local dir=$1
    shift
    RC=0
    OUT=$("$GATES" "$TASK/$dir" "$@" 2>&1) || RC=$?
}

expect_rc() { [[ $RC -eq $1 ]] || fail "$2: exit $RC, expected $1: $OUT"; }
expect_has() { grep -qF -- "$1" <<< "$OUT" || fail "$2: output lacks '$1': $OUT"; }

# Declared gates: a passing one, then the summary and exit 0.
make_repo pass
printf '%s\n' '# comment lines and blanks are skipped' '' 'ok: true' > "$TASK/pass/.task-gates"
commit_in pass 'gates'
run_gates pass
expect_rc 0 'declared pass'
expect_has 'gates: 1 from .task-gates' 'declared pass'
expect_has 'PASS clean-tree (exit 0,' 'declared pass'
expect_has 'PASS ahead-of-base (exit 0,' 'declared pass'
expect_has 'PASS no-ai-trailers (exit 0,' 'declared pass'
expect_has 'PASS ok (exit 0,' 'declared pass'
expect_has 'task-gates: pass (4 checks)' 'declared pass'
pass 'declared gates that pass: exit 0, one PASS line per check'

# A failing gate: FAIL with its exit code, and only the last 20 lines of its output.
make_repo fail
printf '%s\n' 'bad: for i in $(seq 25); do echo "line $i"; done; exit 3' > "$TASK/fail/.task-gates"
commit_in fail 'gates'
run_gates fail
expect_rc 1 'declared fail'
expect_has 'FAIL bad (exit 3,' 'declared fail'
expect_has '    line 25' 'declared fail'
expect_has '    line 6' 'declared fail'
grep -qx '    line 5' <<< "$OUT" && fail 'declared fail: printed more than the last 20 lines'
[[ $(grep -c '^    line ' <<< "$OUT") -eq 20 ]] || fail "declared fail: expected 20 output lines: $OUT"
expect_has 'task-gates: fail (1 of 4 checks failed)' 'declared fail'
pass 'a failing gate: exit 1, FAIL with its exit code, last 20 output lines'

# A gate that runs too long is cut off by the timeout and fails.
make_repo slow
printf '%s\n' 'slow: sleep 5' > "$TASK/slow/.task-gates"
commit_in slow 'gates'
RC=0
OUT=$(TASK_GATE_TIMEOUT=1 "$GATES" "$TASK/slow" 2>&1) || RC=$?
expect_rc 1 'timeout'
expect_has 'FAIL slow (exit 124,' 'timeout'
pass 'a gate past TASK_GATE_TIMEOUT fails with exit 124'

# A malformed .task-gates line is a usage error (2), and nothing runs.
make_repo badline
printf '%s\n' 'no colon here' > "$TASK/badline/.task-gates"
commit_in badline 'gates'
run_gates badline
expect_rc 2 'bad line'
expect_has "needs 'name: command'" 'bad line'
make_repo badname
printf '%s\n' 'bad/name: true' > "$TASK/badname/.task-gates"
commit_in badname 'gates'
run_gates badname
expect_rc 2 'bad name'
pass 'a malformed .task-gates line exits 2'

# No .task-gates: the defaults that match the repo are listed. --list does not run them.
make_repo detect
printf '{"scripts": {"lint": "eslint .", "test": "vitest", "build": "tsc"}}\n' > "$TASK/detect/package.json"
printf 'lockfile\n' > "$TASK/detect/pnpm-lock.yaml"
printf 'test:\n\techo test\n' > "$TASK/detect/Makefile"
printf 'module fixture\n' > "$TASK/detect/go.mod"
mkdir -p "$TASK/detect/tests" && printf '[project]\nname = "fixture"\n' > "$TASK/detect/pyproject.toml"
printf 'echo hi\n' > "$TASK/detect/app.sh"
commit_in detect 'defaults'
run_gates detect --list
expect_rc 0 'detected list'
expect_has 'shellcheck: shellcheck -x app.sh' 'detected list'
expect_has 'package:lint: pnpm run lint' 'detected list'
expect_has 'package:test: pnpm run test' 'detected list'
grep -q 'package:typecheck' <<< "$OUT" && fail 'detected list: typecheck was listed without a script'
expect_has 'make:test: make test' 'detected list'
expect_has 'pytest: pytest' 'detected list'
expect_has 'go-test: go test ./...' 'detected list'
pass 'defaults detected: shellcheck on changed .sh files, package scripts by lockfile, make test, pytest, go test'

# npm is the default package manager without a lockfile.
make_repo npm
printf '{"scripts": {"test": "jest"}}\n' > "$TASK/npm/package.json"
commit_in npm 'package'
run_gates npm --list
expect_has 'package:test: npm run test' 'npm default'
pass 'package.json without a lockfile uses npm'

# A branch with no shell, package, make, python or go files has no defaults: exit 3.
make_repo nothing
run_gates nothing --list
expect_rc 3 'no defaults'
expect_has 'no gates declared' 'no defaults'
pass 'no .task-gates and no defaults: exit 3'

# Dirty tree: an ignored file passes; untracked and modified tracked files fail.
make_repo dirty
printf '%s\n' 'ok: true' > "$TASK/dirty/.task-gates"
commit_in dirty 'gates'
printf 'scratch\n' > "$TASK/dirty/scratch.tmp"
run_gates dirty
expect_rc 0 'ignored file'
expect_has 'PASS clean-tree' 'ignored file'
printf 'notes\n' > "$TASK/dirty/notes.txt"
run_gates dirty
expect_rc 1 'untracked file'
expect_has 'FAIL clean-tree (exit 1,' 'untracked file'
expect_has '?? notes.txt' 'untracked file'
rm "$TASK/dirty/notes.txt"
printf 'changed\n' >> "$TASK/dirty/feature.txt"
run_gates dirty
expect_rc 1 'modified file'
expect_has ' M feature.txt' 'modified file'
"${GIT[@]}" -C "$TASK/dirty" checkout -q -- feature.txt
run_gates dirty
expect_rc 0 'clean again'
pass 'dirty tree: untracked and modified files fail, ignored files pass'

# An empty branch (no commits ahead of main) fails the ahead check.
make_repo empty
git -C "$TASK/empty" checkout -q main
git -C "$TASK/empty" checkout -q -B feature main
run_gates empty
expect_rc 1 'not ahead'
expect_has 'FAIL ahead-of-base' 'not ahead'
expect_has 'no commits in main..HEAD' 'not ahead'
pass 'a branch with no commits past base fails'

# --base: an unknown ref is a usage error; a known one is used for the checks.
run_gates pass --base nosuch
expect_rc 2 'unknown base'
run_gates pass --base main
expect_rc 0 'explicit base'
expect_has 'PASS ahead-of-base' 'explicit base'
pass '--base: unknown is exit 2, a given ref is used'

# AI trailers: only commits in base..HEAD count; an old one on main does not.
make_repo oldtrailer
git -C "$TASK/oldtrailer" checkout -q main
printf 'x\n' > "$TASK/oldtrailer/x.txt"
"${GIT[@]}" -C "$TASK/oldtrailer" add -A
"${GIT[@]}" -C "$TASK/oldtrailer" commit -q -m 'old' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
git -C "$TASK/oldtrailer" checkout -q feature
printf '%s\n' 'ok: true' > "$TASK/oldtrailer/.task-gates"
commit_in oldtrailer 'gates'
run_gates oldtrailer
expect_rc 0 'trailer on main'
pass 'a trailer on a commit outside base..HEAD is not checked'

make_repo trailer
printf '%s\n' 'ok: true' > "$TASK/trailer/.task-gates"
commit_in trailer 'gates' 'Co-Authored-By: Claude <noreply@anthropic.com>'
run_gates trailer
expect_rc 1 'co-author trailer'
expect_has 'FAIL no-ai-trailers (exit 1,' 'co-author trailer'
expect_has 'Co-Authored-By: Claude' 'co-author trailer'
pass 'a Co-Authored-By trailer in base..HEAD fails the check'

make_repo generated
printf '%s\n' 'ok: true' > "$TASK/generated/.task-gates"
commit_in generated 'gates' '🤖 Generated with [Claude Code](https://claude.com/claude-code)'
run_gates generated
expect_rc 1 'generated-with trailer'
expect_has 'FAIL no-ai-trailers' 'generated-with trailer'
pass 'a "Generated with Claude" line fails the check'

# --json: one report per head commit under <task-root>/reports/orchestrator.
run_gates fail --json
expect_rc 1 'json fail'
REPORT="$TASK/reports/orchestrator/gates-fail-$(git -C "$TASK/fail" rev-parse --short=7 HEAD).json"
[[ -f "$REPORT" ]] || fail "json: no report at $REPORT"
jq -e --arg head "$(git -C "$TASK/fail" rev-parse HEAD)" '
    .repo == "fail" and .result == "fail" and .exit == 1 and .source == ".task-gates"
    and .head_sha == $head and .base == "main" and (.checks | length) == 4
    and (.checks[0].name == "clean-tree") and (.checks[3].name == "bad") and (.checks[3].exit == 3)
    and (.checks[3].duration_ms | type == "number")' "$REPORT" >/dev/null || fail "json: wrong report: $(cat "$REPORT")"
run_gates pass --json
expect_rc 0 'json pass'
jq -e '.result == "pass" and .exit == 0 and ([.checks[].exit] | all(. == 0))' \
    "$TASK/reports/orchestrator/gates-pass-$(git -C "$TASK/pass" rev-parse --short=7 HEAD).json" >/dev/null ||
    fail 'json: pass report is wrong'
run_gates nothing --json
expect_rc 3 'json no gates'
jq -e '.result == "no-gates" and .exit == 3 and .source == "none"' \
    "$TASK/reports/orchestrator/gates-nothing-$(git -C "$TASK/nothing" rev-parse --short=7 HEAD).json" >/dev/null ||
    fail 'json: no-gates report is wrong'
pass '--json writes the report per head commit: result, exit, source and each check'

# Usage errors: no worktree, an unknown option, and a folder that is not a git worktree.
RC=0; OUT=$("$GATES" 2>&1) || RC=$?; expect_rc 2 'no args'
RC=0; OUT=$("$GATES" "$TASK/pass" --bogus 2>&1) || RC=$?; expect_rc 2 'unknown option'
mkdir -p "$TASK/plain"
RC=0; OUT=$("$GATES" "$TASK/plain" 2>&1) || RC=$?; expect_rc 2 'not a worktree'
pass 'usage errors exit 2'
