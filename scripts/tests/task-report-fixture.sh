#!/usr/bin/env bash
# task-report.py accepts a valid C4 report for a repo agent and for the
# researcher, and rejects each schema violation and a path that does not name
# the report's agent and step. Writes only inside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK="$ROOT/env/.config/tmux/scripts/task-report.py"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

REPORTS="$TMP_ROOT/tasks/fixture/reports"
mkdir -p "$REPORTS/dotfiles" "$REPORTS/researcher"

# A valid repo report, written as the file the agent would write.
valid() {
    cat <<'EOF'
{
  "step": "9",
  "agent": "dotfiles",
  "branch": "improve-omarchy-agents",
  "head_sha": "0159add",
  "files_changed": ["env/.config/tmux/scripts/task-agent.sh"],
  "checks": [{"cmd": "shellcheck task-agent.sh", "exit": 0}],
  "risks": [],
  "needs_decision": null,
  "context_estimate_k": 42,
  "summary": "Structured reports and assignment hooks."
}
EOF
}

# Runs the checker on a report file; prints its output and returns its status.
run_check() { python3 -I "$CHECK" check "$1"; }

# expect_ok <file> <label>: the report must pass.
expect_ok() {
    local out
    out=$(run_check "$1") || fail "$2 was rejected: $out"
    [[ "$out" == "ok $1" ]] || fail "$2 printed '$out'"
    printf 'PASS: %s\n' "$2"
}

# expect_bad <file> <label> <message fragment>: the report must fail with it.
expect_bad() {
    local out status=0
    out=$(run_check "$1") || status=$?
    [[ $status -eq 1 ]] || fail "$2 exited $status, expected 1: $out"
    [[ "$out" == *"$3"* ]] || fail "$2 did not report '$3': $out"
}

write_report() { valid | python3 -c 'import json, sys; r = json.load(sys.stdin); exec(sys.argv[1]); json.dump(r, sys.stdout)' "$1" > "$2"; }

valid > "$REPORTS/dotfiles/9.json"
expect_ok "$REPORTS/dotfiles/9.json" 'valid repo report'

write_report 'del r["summary"]' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'missing summary' 'report: missing summary'

write_report 'r["status"] = "done"' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'unknown field' 'report: unknown field status'

write_report 'r["head_sha"] = "XYZ"' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'bad head_sha' 'report.head_sha: does not match'

write_report 'r["summary"] = "two\nlines"' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'multi-line summary' 'report.summary: does not match'

write_report 'r["summary"] = "one line\n"' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'summary with a trailing newline' 'report.summary: does not match'

write_report 'r["summary"] = "x" * 201' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'summary over 200 characters' 'report.summary: longer than 200'

write_report 'r["checks"] = [{"cmd": "make", "exit": 256}]' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'exit code above 255' 'report.checks[0].exit: above 255'

write_report 'r["files_changed"] = "task-agent.sh"' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'files_changed as a string' 'report.files_changed: expected array'

write_report 'r["context_estimate_k"] = "42"' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'context estimate as text' 'report.context_estimate_k: expected integer'

write_report 'r["needs_decision"] = ""' "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'empty needs_decision' 'report.needs_decision: shorter than 1'

# The path must name the same agent and step as the contents.
valid > "$REPORTS/dotfiles/10.json"
expect_bad "$REPORTS/dotfiles/10.json" 'file name that is not the step' 'path: file must be reports/<agent>/<step>.json'
mkdir -p "$REPORTS/other"
valid > "$REPORTS/other/9.json"
expect_bad "$REPORTS/other/9.json" 'folder that is not the agent' 'path: file must be reports/<agent>/<step>.json'
mkdir -p "$TMP_ROOT/elsewhere/dotfiles"
valid > "$TMP_ROOT/elsewhere/dotfiles/9.json"
expect_bad "$TMP_ROOT/elsewhere/dotfiles/9.json" 'report outside reports/' 'path: report is not under reports/<agent>/'
printf 'PASS: a report must sit at reports/<agent>/<step>.json for its own agent and step\n'
printf 'PASS: each schema violation is rejected with its field named (missing, unknown, pattern, length, range, type)\n'

printf 'not json' > "$REPORTS/dotfiles/9.json"
expect_bad "$REPORTS/dotfiles/9.json" 'invalid JSON' 'cannot read as JSON'

# The researcher: no branch or commit, and its notes under files_changed.
cat > "$REPORTS/researcher/4.json" <<'EOF'
{
  "step": "4",
  "agent": "researcher",
  "branch": null,
  "head_sha": null,
  "files_changed": ["research/codegraph-ponytail.md"],
  "checks": [],
  "risks": ["Source retrieved 2026-10-15 only."],
  "needs_decision": null,
  "context_estimate_k": 12,
  "summary": "Ranked port list written."
}
EOF
expect_ok "$REPORTS/researcher/4.json" 'valid researcher report with null branch and head_sha'

# The checker's usage error exits 2.
status=0
python3 -I "$CHECK" > /dev/null 2>&1 || status=$?
[[ $status -eq 2 ]] || fail "no arguments exited $status, expected 2"
printf 'PASS: no arguments is a usage error (exit 2)\n'
