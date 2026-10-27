#!/usr/bin/env bash
# shellcheck disable=SC2016 # the Notes texts carry literal backticks
# task-sessionizer.sh sync brings an older task up to the current templates. It
# adds allow rules (none removed or reordered), missing subagents, folders and
# context clones, and replaces the Notes section only when it holds a text this
# script wrote. Legacy names and behind branches are reported. A dry run changes
# nothing, a second run is a no-op, and no canonical checkout is written.
# Writes only inside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SESSIONIZER="$ROOT/env/.config/tmux/scripts/task-sessionizer.sh"
TMP_ROOT=$(mktemp -d)
HOME="$TMP_ROOT/home"
TASKS_DIR="$TMP_ROOT/tasks"
BIN="$TMP_ROOT/bin"
HERDR_LOG="$TMP_ROOT/herdr.log"
HERDR_AGENTS="$TMP_ROOT/agents.json"
export HOME TASKS_DIR HERDR_LOG HERDR_AGENTS
mkdir -p "$HOME/Projects" "$HOME/Work/group" "$TASKS_DIR" "$BIN"
PATH="$BIN:/usr/bin:/bin"
export PATH

cat > "$BIN/tmux" <<'EOF'
#!/bin/sh
case "$1" in
    has-session) exit 1 ;;
    list-windows) exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$BIN/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$*" in
    *'session list'*) printf 'legacy  running\n' ;;
    *'agent list'*) cat "$HERDR_AGENTS" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$BIN/tmux" "$BIN/herdr"

cleanup() {
    python3 - "$TMP_ROOT" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
canon_state() { find "$1/.git" -printf '%P %s %T@\n' | sort; }
tree_state() { find "$1" -printf '%P %s %T@\n' | sort; }
make_repo() {
    local path=$1
    mkdir -p "$path"
    git -C "$path" init -q -b main
    git -C "$path" config user.name Fixture
    git -C "$path" config user.email fixture@example.invalid
    printf '%s\n' "$path" > "$path/README.md"
    git -C "$path" add README.md
    git -C "$path" commit -qm init
}

worker_repo="$HOME/Projects/worker"
ctx_repo="$HOME/Work/group/ctx"
make_repo "$worker_repo"
make_repo "$ctx_repo"
printf 'context doc\n' > "$ctx_repo/doc.txt"
git -C "$ctx_repo" add doc.txt
git -C "$ctx_repo" commit -qm 'context doc'

# A task as the previous versions left it: old settings, an old Notes section,
# a worker named after its repo (the worker worktree is on the task branch), a
# context repo with no clone, and no hooks/, reports/ or subagents.
notes_v2='## Notes for agents
- Worker repo subfolders are task worktrees on the branch shown in Repo modes. Each worker writes only inside its assigned worktree.
- Context-only repos are canonical checkouts listed in Repo modes; they are read-only references with no worktree or repo agent.
- Researcher notes belong under the task root'"'"'s `research/`; researcher never edits repository trees.
- Don'"'"'t `git checkout` other branches; use the existing task worktrees.
- Each agent'"'"'s role comes from its launch prompt (~/.config/tmux/scripts/task-roles/). The orchestrator maintains the task plan and shared contracts.'
legacy="$TASKS_DIR/legacy"
mkdir -p "$legacy/.claude"
git -C "$worker_repo" worktree add -q -b legacy "$legacy/worker"
printf '%s\n' '# legacy' '' '## Goal' '' '## Repos' '' '## Agents' '| name | role |' '|---|---|' '' "$notes_v2" > "$legacy/AGENTS.md"
ln -s AGENTS.md "$legacy/CLAUDE.md"
printf 'worker\n' > "$legacy/.task-worker-order"
printf 'ctx\t%s\n' "$ctx_repo" > "$legacy/.task-context.tsv"
cat > "$legacy/.claude/settings.json" <<EOF
{
  "permissions": {
    "allow": [
      "Bash(herdr:*)",
      "Bash(~/.config/tmux/scripts/task-agent.sh:*)",
      "Bash($HOME/.config/tmux/scripts/task-agent.sh:*)"
    ]
  }
}
EOF
cp "$legacy/.claude/settings.json" "$TMP_ROOT/legacy-settings.orig"
# The worker branch falls behind main: a commit lands on main after it was cut.
git -C "$worker_repo" commit -q --allow-empty -m 'main moves on'
cat > "$HERDR_AGENTS" <<EOF
{"result":{"agents":[
  {"pane_id":"w1:p1","agent":"claude","agent_status":"idle","cwd":"$legacy"},
  {"pane_id":"w2:p1","name":"worker","agent":"claude","agent_status":"idle","cwd":"$legacy/worker"}
]}}
EOF

# A second task with the legacy folder names: hooks/ and reports/ named after its repo.
oldnames="$TASKS_DIR/oldnames"
mkdir -p "$oldnames/hooks" "$oldnames/reports/worker"
git -C "$worker_repo" worktree add -q -b oldnames "$oldnames/worker" main
printf 'assignment\n' > "$oldnames/hooks/worker.md"
printf '{}\n' > "$oldnames/reports/worker/1.json"
printf '# oldnames\n\n## Notes for agents\n- Old note.\n' > "$oldnames/AGENTS.md"

# A task whose Notes section the user customised: the stock text plus their own bullet.
custom="$TASKS_DIR/custom"
mkdir -p "$custom/.claude"
printf '%s\n' '# custom' '' "$notes_v2" '' '- Standing user preference: keep this bullet.' > "$custom/AGENTS.md"
cp "$legacy/.claude/settings.json" "$custom/.claude/settings.json"
printf '%s\n' '{' '  "permissions": {' '    "allow": ["Bash(herdr:*)", "Bash(git status:*)"]' '  }' '}' > "$custom/.claude/settings.json"
mkdir -p "$custom/.claude/agents"
cp "$ROOT/env/.config/tmux/scripts/task-roles/subagents/status-reader.md" "$custom/.claude/agents/status-reader.md"
printf 'edited by the user\n' > "$custom/.claude/agents/status-reader.md"
# An older managed copy: it carries the marker, so sync refreshes it.
printf -- '---\nname: diff-reviewer\nmodel: sonnet\n---\n<!-- managed: task-roles -->\nold text\n' > "$custom/.claude/agents/diff-reviewer.md"

# A task whose settings.json is not JSON: left as it is.
badjson="$TASKS_DIR/badjson"
mkdir -p "$badjson/.claude"
printf '# badjson\n' > "$badjson/AGENTS.md"
printf '{ not json\n' > "$badjson/.claude/settings.json"

# The current Notes text, read from the script, with and without its markers.
current_notes=$(python3 - "$ROOT/env/.config/tmux/scripts/task-sessionizer.sh" <<'NOTES_PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
start = lines.index("AGENTS_NOTES=$(cat <<'EOF'") + 1
print("\n".join(lines[start:lines.index("EOF", start)]))
NOTES_PY
)
markerless_notes=$(grep -v 'task-sessionizer:notes:' <<< "$current_notes")
# A task with the current text already (nothing to do), one with the same text
# but no markers (markers are added), one with the version-1 text (replaced),
# and a bare task with no settings.json (created from the template).
mkdir -p "$TASKS_DIR/current" "$TASKS_DIR/markerless" "$TASKS_DIR/v1notes" "$TASKS_DIR/bare"
printf '# current\n\n%s\n' "$current_notes" > "$TASKS_DIR/current/AGENTS.md"
printf '# markerless\n\n%s\n' "$markerless_notes" > "$TASKS_DIR/markerless/AGENTS.md"
printf '%s\n' '# v1notes' '' '## Notes for agents' \
    '- Each repo subfolder is a git worktree on branch v1notes. Work only inside your own subfolder; the orchestrator works at the task root.' \
    '- Don'"'"'t `git checkout` other branches; use the existing worktrees.' \
    '- Each agent'"'"'s role comes from its launch prompt (~/.config/tmux/scripts/task-roles/). This file holds only the task'"'"'s shared state; only the orchestrator edits it.' \
    > "$TASKS_DIR/v1notes/AGENTS.md"
printf '# bare\n' > "$TASKS_DIR/bare/AGENTS.md"

# A folder that is not a task (no AGENTS.md) is not a task for --all.
mkdir -p "$TASKS_DIR/notatask"

canonical_before=$(canon_state "$worker_repo")
ctx_canonical_before=$(canon_state "$ctx_repo")
legacy_before=$(tree_state "$legacy")
legacy_head_before=$(git -C "$legacy/worker" rev-parse HEAD)
legacy_head_notes_before=$(sed '/^## Notes for agents/,$d' "$legacy/AGENTS.md")
notes_before=$(cat "$custom/AGENTS.md")

# --- dry run ----------------------------------------------------------------
: > "$HERDR_LOG"
dry=$("$SESSIONIZER" sync legacy --dry-run) || fail "dry run failed: $dry"
[[ "$(tree_state "$legacy")" == "$legacy_before" ]] || fail 'dry run changed the task folder'
[[ "$(canon_state "$worker_repo")" == "$canonical_before" ]] || fail 'dry run wrote the worker canonical .git'
[[ ! -e "$legacy/research/context/ctx" ]] || fail 'dry run made a context clone'
grep -Fq 'planned: settings.json: +17 allow rule(s)' <<< "$dry" || fail "dry run did not plan the settings rules: $dry"
grep -Fq 'planned: .claude/agents: copy or refresh diff-reviewer.md repo-scout.md status-reader.md test-runner.md web-scout.md' <<< "$dry" || fail "dry run did not plan the subagents: $dry"
grep -Fq 'planned: hooks/: create' <<< "$dry" || fail 'dry run did not plan hooks/'
grep -Fq 'planned: reports/: create' <<< "$dry" || fail 'dry run did not plan reports/'
grep -Fq "planned: research/context/ctx: clone of $ctx_repo" <<< "$dry" || fail 'dry run did not plan the context clone'
grep -Fq 'planned: AGENTS.md Notes: replace the earlier generated text' <<< "$dry" || fail 'dry run did not plan the Notes replacement'
grep -Fq 'report: herdr: orchestrator is unnamed (pane w1:p1); name it: herdr --session legacy agent rename w1:p1 orchestrator' <<< "$dry" ||
    fail "dry run did not report the unnamed orchestrator: $dry"
grep -Fq 'report: herdr: agent worker (pane w2:p1) should be worker-worker; restart: TASK_SESSION=legacy' <<< "$dry" ||
    fail "dry run did not report the legacy worker name: $dry"
grep -Fq "start worker worker w2:p1 $worker_repo --auto" <<< "$dry" || fail 'restart command lacks the start line'
grep -Fq 'report: worker: branch legacy is 1 commit(s) behind main' <<< "$dry" || fail "dry run did not report the behind branch: $dry"
grep -Fq 'info: context clones are left as they are; task-sessionizer.sh refresh legacy' <<< "$dry" || fail 'dry run did not mention refresh'
grep -Fq 'legacy: 6 change(s) planned; 0 for review; 3 report(s)' <<< "$dry" || fail "dry run summary is wrong: $dry"
if grep -Eq '^(made|planned): .*(agents-md|notes)' <<< "$dry"; then fail 'dry run wording leaked'; fi
# Read-only: only session and agent listings reached herdr.
if grep -Evq '^(session list|--session legacy agent list)' "$HERDR_LOG"; then
    fail "sync sent a mutating herdr command: $(cat "$HERDR_LOG")"
fi
printf 'PASS: dry run plans every change, reports the rest, and changes nothing\n'

# --- real run ---------------------------------------------------------------
real=$("$SESSIONIZER" sync legacy) || fail "sync failed: $real"
grep -Fq 'made: settings.json: +17 allow rule(s)' <<< "$real" || fail "sync did not add the rules: $real"
grep -Fq 'legacy: 6 change(s) made; 0 for review; 3 report(s)' <<< "$real" || fail "sync summary is wrong: $real"

settings="$legacy/.claude/settings.json"
expected_rules=(
    "Bash(herdr:*)"
    "Bash(herdr agent wait:*)"
    "Bash(~/.config/tmux/scripts/task-agent.sh:*)"
    "Bash($HOME/.config/tmux/scripts/task-agent.sh:*)"
    "Bash(~/.config/tmux/scripts/task-sessionizer.sh refresh:*)"
    "Bash($HOME/.config/tmux/scripts/task-sessionizer.sh refresh:*)"
    "Bash(~/.config/tmux/scripts/task-sessionizer.sh promote:*)"
    "Bash($HOME/.config/tmux/scripts/task-sessionizer.sh promote:*)"
    "Bash(~/.config/tmux/scripts/task-sessionizer.sh demote:*)"
    "Bash($HOME/.config/tmux/scripts/task-sessionizer.sh demote:*)"
    "Bash(~/.config/tmux/scripts/task-decide.py:*)"
    "Bash($HOME/.config/tmux/scripts/task-decide.py:*)"
    "Bash(python3 ~/.config/tmux/scripts/task-decide.py:*)"
    "Bash(python3 $HOME/.config/tmux/scripts/task-decide.py:*)"
    "Bash(python3 ~/.config/tmux/scripts/task-dispatch.py:*)"
    "Bash(python3 $HOME/.config/tmux/scripts/task-dispatch.py:*)"
    "Bash(~/.config/tmux/scripts/task-sessionizer.sh sync:*)"
    "Bash($HOME/.config/tmux/scripts/task-sessionizer.sh sync:*)"
    "Bash(~/.config/tmux/scripts/task-gates.sh:*)"
    "Bash($HOME/.config/tmux/scripts/task-gates.sh:*)"
)
python3 - "$settings" "$TMP_ROOT/legacy-settings.orig" "${expected_rules[@]}" <<'PY'
import json, sys
settings, original, *expected = sys.argv[1:]
doc = json.load(open(settings))
allow = doc["permissions"]["allow"]
before = json.load(open(original))["permissions"]["allow"]
assert allow[:len(before)] == before, "existing rules moved or changed"
assert sorted(allow) == sorted(set(expected)) and len(allow) == len(expected), f"unexpected rules: {allow}"
assert list(doc) == ["permissions"], "other keys changed"
PY
backups=("$legacy"/.claude/settings.json.bak-*)
[[ ${#backups[@]} -eq 1 ]] || fail 'expected one settings backup'
cmp -s "$TMP_ROOT/legacy-settings.orig" "${backups[0]}" || fail 'the backup is not the previous settings file'
for name in status-reader diff-reviewer web-scout repo-scout test-runner; do
    cmp -s "$legacy/.claude/agents/$name.md" "$ROOT/env/.config/tmux/scripts/task-roles/subagents/$name.md" ||
        fail "subagent $name was not copied from the template"
done
[[ -d "$legacy/hooks" && -d "$legacy/reports" ]] || fail 'hooks/ or reports/ was not created'
[[ -L "$legacy/CLAUDE.md" ]] || fail 'CLAUDE.md link was disturbed'
clone="$legacy/research/context/ctx"
[[ $(git -C "$clone" rev-parse HEAD) == $(git -C "$ctx_repo" rev-parse HEAD) ]] || fail 'the context clone is not at the canonical HEAD'
[[ $(git -C "$clone" config --get remote.origin.url) == "$ctx_repo" ]] || fail 'the context clone does not point at the canonical'
[[ "$(canon_state "$ctx_repo")" == "$ctx_canonical_before" ]] || fail 'the context clone wrote into the canonical checkout'
[[ "$(canon_state "$worker_repo")" == "$canonical_before" ]] || fail 'sync wrote the worker canonical .git'
[[ $(git -C "$legacy/worker" rev-parse HEAD) == "$legacy_head_before" ]] || fail 'sync moved the worker branch'
[[ $(git -C "$legacy/worker" branch --show-current) == legacy ]] || fail 'sync changed the worker branch'
[[ -z "$(git -C "$legacy/worker" status --porcelain)" ]] || fail 'sync touched the worker worktree'
# The Notes section now carries the markers and the current text; everything
# above it is unchanged.
grep -Fq '<!-- task-sessionizer:notes:start -->' "$legacy/AGENTS.md" || fail 'Notes markers were not written'
grep -Fq 'Agent names: `orchestrator`' "$legacy/AGENTS.md" || fail 'current Notes text was not written'
if grep -Fq 'Each repo subfolder' "$legacy/AGENTS.md"; then fail 'old Notes text remains'; fi
[[ "$(sed '/^## Notes for agents/,$d' "$legacy/AGENTS.md")" == "$legacy_head_notes_before" ]] || fail 'sync changed AGENTS.md above the Notes section'
printf 'PASS: sync adds rules without removing any, copies subagents, creates folders and the clone, and replaces the old Notes\n'

# --- second run is a no-op --------------------------------------------------
after_first=$(tree_state "$legacy")
canonical_after_real=$(canon_state "$worker_repo")
second=$("$SESSIONIZER" sync legacy)
[[ "$(canon_state "$worker_repo")" == "$canonical_after_real" ]] || fail 'second run wrote the worker canonical .git'
grep -Eq '^(made|planned): ' <<< "$second" && fail "second run changed something: $second"
[[ "$(tree_state "$legacy")" == "$after_first" ]] || fail 'second run changed the task folder'
grep -Fq 'legacy: up to date; 0 for review; 3 report(s)' <<< "$second" || fail "second run summary is wrong: $second"
printf 'PASS: a second run changes nothing and writes no canonical checkout\n'

# A running Codex worker with an assignment hook: the report asks for hook approval.
legacy_agents_json=$(cat "$HERDR_AGENTS")
printf '%s\n' '{"result":{"agents":[{"pane_id":"w2:p1","name":"worker-worker","agent":"codex","agent_status":"idle","cwd":"'"$legacy"'/worker"}]}}' > "$HERDR_AGENTS"
printf 'assignment\n' > "$legacy/hooks/worker-worker.md"
codex_out=$("$SESSIONIZER" sync legacy --dry-run)
grep -Fq 'report: codex: a Codex agent here may need the assignment hook approved once in /hooks' <<< "$codex_out" ||
    fail "codex hook trust not reported: $codex_out"
if grep -Eq '^(planned|made|review): ' <<< "$codex_out"; then fail "codex check changed something: $codex_out"; fi
rm -f "$legacy/hooks/worker-worker.md"
printf '%s\n' "$legacy_agents_json" > "$HERDR_AGENTS"
printf 'PASS: a running Codex worker with an assignment hook is reported for hook approval\n'

# --- Notes variants and a missing settings file -------------------------------
current_out=$("$SESSIONIZER" sync current)
if grep -Fq 'AGENTS.md Notes' <<< "$current_out"; then fail "a current Notes section was touched: $current_out"; fi
markerless_out=$("$SESSIONIZER" sync markerless)
grep -Fq 'made: AGENTS.md Notes: add the start and end markers' <<< "$markerless_out" || fail "markerless Notes not wrapped: $markerless_out"
[[ "$(cat "$TASKS_DIR/markerless/AGENTS.md")" == "$(printf '# markerless\n\n%s\n' "$current_notes")" ]] || fail 'markerless Notes text changed beyond the markers'
v1_out=$("$SESSIONIZER" sync v1notes)
grep -Fq 'made: AGENTS.md Notes: replace the earlier generated text' <<< "$v1_out" || fail "version-1 Notes not replaced: $v1_out"
[[ "$(cat "$TASKS_DIR/v1notes/AGENTS.md")" == "$(printf '# v1notes\n\n%s\n' "$current_notes")" ]] || fail 'version-1 Notes were not replaced by the current text'
bare_out=$("$SESSIONIZER" sync bare)
grep -Fq 'made: .claude/settings.json: create from the current template' <<< "$bare_out" || fail "missing settings not created: $bare_out"
jq -e '.permissions.allow | length == 20 and .[0] == "Bash(herdr:*)" and (.[17] | endswith("task-sessionizer.sh sync:*)"))' \
    "$TASKS_DIR/bare/.claude/settings.json" >/dev/null || fail 'created settings are not the template'
[[ -L "$TASKS_DIR/bare/CLAUDE.md" ]] || fail 'CLAUDE.md link was not created'
printf 'PASS: current Notes are left alone, marker-less and version-1 Notes are updated, and a missing settings file is created\n'

# --- customised Notes, edited subagent, custom rule, invalid JSON -------------
custom_dry=$("$SESSIONIZER" sync custom --dry-run)
grep -Fq 'review: AGENTS.md: Notes section differs from the template; left as it is' <<< "$custom_dry" || fail "customised Notes not held: $custom_dry"
grep -Fq '+- Standing user preference: keep this bullet.' <<< "$custom_dry" || fail 'diff does not show the custom bullet'
grep -Fq 'review: .claude/agents/status-reader.md has no managed marker and differs from the template; kept' <<< "$custom_dry" || fail 'edited subagent not reported'
custom_out=$("$SESSIONIZER" sync custom)
[[ "$(cat "$custom/AGENTS.md")" == "$notes_before" ]] || fail 'customised Notes were changed'
[[ $(cat "$custom/.claude/agents/status-reader.md") == 'edited by the user' ]] || fail 'edited subagent was replaced'
cmp -s "$custom/.claude/agents/diff-reviewer.md" "$ROOT/env/.config/tmux/scripts/task-roles/subagents/diff-reviewer.md" ||
    fail 'a managed subagent was not refreshed'
grep -Fq 'Bash(git status:*)' "$custom/.claude/settings.json" || fail 'custom rule was removed'
jq -e '.permissions.allow | index("Bash(git status:*)") == 1 and index("Bash(herdr:*)") == 0' "$custom/.claude/settings.json" >/dev/null ||
    fail 'custom rule moved'
jq -e '.permissions.allow | length == 21' "$custom/.claude/settings.json" >/dev/null || fail 'custom settings did not gain the template rules'
grep -Fq 'custom: 5 change(s) made; 2 for review; 0 report(s)' <<< "$custom_out" || fail "custom summary is wrong: $custom_out"
close_custom=$("$SESSIONIZER" close custom --dry-run 2>&1 || true)
grep -Fq 'custom task-root data in .claude' <<< "$close_custom" || fail "close does not flag the custom rule: $close_custom"
printf 'PASS: a customised Notes section, an edited subagent and a custom rule are kept; close still flags the custom rule\n'

bad_out=$("$SESSIONIZER" sync badjson)
grep -Fq 'review: settings.json: not a settings file with permissions.allow; left as it is' <<< "$bad_out" || fail "invalid JSON not held: $bad_out"
[[ $(cat "$badjson/.claude/settings.json") == '{ not json' ]] || fail 'invalid settings file was rewritten'
printf 'PASS: an unreadable settings file is reported and left alone\n'

# --- legacy folder names are reported, not moved ----------------------------
old_out=$("$SESSIONIZER" sync oldnames --dry-run)
grep -Fq 'report: hooks/worker.md is named after a repo; the agent reads hooks/worker-worker.md: mv hooks/worker.md hooks/worker-worker.md' <<< "$old_out" ||
    fail "legacy hook name not reported: $old_out"
grep -Fq 'report: reports/worker/ is named after a repo; the agent writes reports/worker-worker/: mv reports/worker reports/worker-worker' <<< "$old_out" ||
    fail "legacy report folder not reported: $old_out"
[[ -f "$oldnames/hooks/worker.md" && -d "$oldnames/reports/worker" ]] || fail 'a legacy folder was moved'
printf 'PASS: legacy hooks/ and reports/ names are reported and left in place\n'

# --- --all ------------------------------------------------------------------
before_all=$(tree_state "$legacy")
all_out=$("$SESSIONIZER" sync --all --dry-run)
for task in legacy custom badjson oldnames; do
    [[ $(grep -c "^$task: " <<< "$all_out") -eq 1 ]] || fail "--all lacks exactly one summary line for $task: $all_out"
done
grep -q 'notatask' <<< "$all_out" && fail '--all treated a folder without AGENTS.md as a task'
grep -Eq '^(planned|made|review|report|info): ' <<< "$all_out" && fail "--all printed details: $all_out"
[[ "$(tree_state "$legacy")" == "$before_all" ]] || fail '--all --dry-run changed the task folder'
printf 'PASS: --all prints one summary line per task and changes nothing in a dry run\n'

# --- argument errors ---------------------------------------------------------
if "$SESSIONIZER" sync >/dev/null 2>&1; then fail 'sync with no task succeeded'; fi
if "$SESSIONIZER" sync nosuch >/dev/null 2>&1; then fail 'sync of an unknown task succeeded'; fi
if "$SESSIONIZER" sync legacy --bogus >/dev/null 2>&1; then fail 'sync accepted an unknown option'; fi
if "$SESSIONIZER" sync --all legacy >/dev/null 2>&1; then fail 'sync accepted --all with a task'; fi
printf 'PASS: sync refuses a missing task, an unknown task, an unknown option and --all with a task\n'

# --- the generated files close and rm treat as generated ---------------------
close_legacy=$("$SESSIONIZER" close legacy --dry-run 2>&1 || true)
if grep -Fq 'custom task-root data in .claude' <<< "$close_legacy"; then
    fail "close flags a synced settings file: $close_legacy"
fi
"$SESSIONIZER" rm legacy >/dev/null 2>&1 || fail 'rm refused a synced task (backup or settings left behind)'
[[ ! -e "$legacy" ]] || fail 'rm left the synced task folder'
printf 'PASS: a synced task closes without custom-data blocks, and rm removes its backup\n'
