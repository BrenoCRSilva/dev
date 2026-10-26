#!/usr/bin/env bash
# Offline checks for task-agent.sh's session record (C1), its --auto/--resume
# decision and the trust writer (C2). A fake herdr answers pane and agent calls,
# a fake claude records the orchestrator's argv, and HOME is a temporary folder,
# so nothing outside it is read or written.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
PICKER="$ROOT/env/.config/tmux/scripts/agent-picker.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "session fixture: FAIL: $*" >&2; exit 1; }
check() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }
refute() { [[ "$1" != *"$2"* ]] || fail "$3: did not expect '$2' in: $1"; }

export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" FAKE_LOG="$TMP/herdr.log"
unset TASK_SESSION TASK_PROVIDER
mkdir -p "$HOME" "$TMP/bin" "$TMP/tasks/t1/research"
TASK=$(realpath "$TMP/tasks/t1")
MAIN="$TMP/Projects/dotfiles"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=f@x -c user.name=f commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$TASK/dotfiles" -b t1
MAIN=$(realpath "$MAIN")
WT="$TASK/dotfiles"
export TASK WT

cat > "$TMP/bin/herdr" <<'STUB'
#!/bin/bash
case "$1 $2" in
    "pane get")
        case "$3" in wpane) cwd=$WT ;; rpane) cwd=$TASK/research ;; *) exit 1 ;; esac
        printf '{"result":{"pane":{"cwd":"%s"}}}\n' "$cwd" ;;
    "agent start") echo "$*" >> "$FAKE_LOG" ;;
    "agent get") printf '{"result":{"agent":{"agent_session":{"value":"%s"}}}}\n' "${FAKE_CODEX_ID:-}" ;;
    *) exit 1 ;;
esac
STUB
printf '#!/bin/sh\necho "$@" > "$FAKE_CLAUDE"\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/herdr" "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" FAKE_CLAUDE="$TMP/claude.args"
RECORD="$TASK/.task-sessions.json"

field() { jq -r --arg a "$1" ".[\$a].$2 // empty" "$RECORD"; }
last_start() { tail -n 1 "$FAKE_LOG"; }
worker() { "$TASK_AGENT" start worker dotfiles wpane "$MAIN" "$@" >/dev/null 2>&1; }

# --- trust (C2) ------------------------------------------------------------------
printf '{"numStartups": 7, "projects": {"/other": {"hasTrustDialogAccepted": false, "x": 1}}}\n' > "$HOME/.claude.json"
chmod 600 "$HOME/.claude.json"
out=$("$TASK_AGENT" --dry-run trust "$TASK")
check "$out" 'would mark trusted' 'trust dry run'
jq -e '.projects | length == 1' "$HOME/.claude.json" >/dev/null || fail 'trust dry run wrote ~/.claude.json'
out=$("$TASK_AGENT" trust "$TASK")
check "$out" 'marked trusted' 'trust writes'
for p in "$TASK" "$TASK/research" "$WT" "$MAIN"; do
    jq -e --arg p "$p" '.projects[$p].hasTrustDialogAccepted == true' "$HOME/.claude.json" >/dev/null || fail "trust missed $p"
done
jq -e '.numStartups == 7 and .projects["/other"] == {"hasTrustDialogAccepted": false, "x": 1}' "$HOME/.claude.json" >/dev/null ||
    fail 'trust lost other keys'
[[ $(stat -c %a "$HOME/.claude.json") == 600 ]] || fail 'trust changed the file mode'
before=$(stat -c %i "$HOME/.claude.json")
check "$("$TASK_AGENT" trust "$TASK")" 'already trusted' 'trust is idempotent'
[[ $(stat -c %i "$HOME/.claude.json") == "$before" ]] || fail 'trust rewrote a file that needed no change'
rm "$HOME/.claude.json"
"$TASK_AGENT" trust "$TASK" >/dev/null
jq -e --arg p "$TASK" '.projects[$p].hasTrustDialogAccepted' "$HOME/.claude.json" >/dev/null || fail 'trust with no ~/.claude.json'
if "$TASK_AGENT" trust "$TMP/missing" 2>/dev/null; then fail 'trust accepted a missing folder'; fi
echo 'PASS: trust marks the task root, research/, the worktree and its main checkout, and keeps other keys'

# Every agent start trusts the task's folders, the orchestrator's included.
rm "$HOME/.claude.json"
(cd "$TASK" && "$TASK_AGENT" orchestrator >/dev/null)
jq -e --arg p "$WT" '.projects[$p].hasTrustDialogAccepted' "$HOME/.claude.json" >/dev/null || fail 'orchestrator start did not trust the task'
rm "$HOME/.claude.json" "$RECORD"
worker
jq -e --arg p "$MAIN" '.projects[$p].hasTrustDialogAccepted' "$HOME/.claude.json" >/dev/null || fail 'worker start did not trust the task'
echo 'PASS: orchestrator and worker starts trust the task folders first'

# --- record and --auto (C1) ----------------------------------------------------------
rm -f "$RECORD"
worker
id=$(field worker-dotfiles session_id)
[[ $id =~ ^[0-9a-f-]{36}$ ]] || fail "fresh worker start recorded no session id: $(cat "$RECORD")"
check "$(last_start)" "--session-id $id" 'fresh claude start passes the recorded id'
[[ $(field worker-dotfiles provider) == claude && $(field worker-dotfiles cwd) == "$WT" && -n $(field worker-dotfiles updated) ]] ||
    fail "record fields: $(cat "$RECORD")"
[[ -z $(find "$TASK" -maxdepth 1 -name '.task-sessions.json.*') ]] || fail 'record left a temp file'

# --auto with no transcript yet starts fresh under a new id.
worker --auto
refute "$(last_start)" '--resume' 'auto without a transcript'
[[ $(field worker-dotfiles session_id) != "$id" ]] || fail 'auto without a transcript kept the old id'
id=$(field worker-dotfiles session_id)

# With the transcript there, --auto resumes it and keeps the id.
mkdir -p "$HOME/.claude/projects/-wt"
touch "$HOME/.claude/projects/-wt/$id.jsonl"
worker --auto
check "$(last_start)" "--resume $id" 'auto resumes the recorded session'
refute "$(last_start)" '--session-id' 'a resume passes no new id'
[[ $(field worker-dotfiles session_id) == "$id" ]] || fail 'resume changed the recorded id'

# A plain start stays fresh even when a session could be resumed.
worker
refute "$(last_start)" '--resume' 'plain start'
id=$(field worker-dotfiles session_id)
touch "$HOME/.claude/projects/-wt/$id.jsonl"

# A record for another provider or folder is not resumed.
jq '.["worker-dotfiles"].cwd = "/elsewhere"' "$RECORD" > "$TMP/r" && mv "$TMP/r" "$RECORD"
worker --auto
refute "$(last_start)" '--resume' 'auto with another cwd'
id=$(field worker-dotfiles session_id)
touch "$HOME/.claude/projects/-wt/$id.jsonl"
FAKE_CODEX_ID=c0de-1 "$TASK_AGENT" --provider codex start worker dotfiles wpane "$MAIN" --auto >/dev/null
refute "$(last_start)" ' resume ' 'codex auto over a claude record'
[[ $(field worker-dotfiles provider) == codex && $(field worker-dotfiles session_id) == c0de-1 ]] ||
    fail "codex start did not record herdr's session id: $(cat "$RECORD")"

# codex resumes by id once its transcript exists.
mkdir -p "$HOME/.codex/sessions/2026/10/26"
touch "$HOME/.codex/sessions/2026/10/26/rollout-2026-10-26T10-00-00-c0de-1.jsonl"
FAKE_CODEX_ID=c0de-1 "$TASK_AGENT" --provider codex start worker dotfiles wpane "$MAIN" --auto >/dev/null
check "$(last_start)" '-- resume c0de-1 ' 'codex auto resumes by id'

# --resume with no record falls back to the newest session in the folder.
rm "$RECORD"
worker --resume
check "$(last_start)" '--continue' 'resume without a record'
FAKE_CODEX_ID='' "$TASK_AGENT" --provider codex start worker dotfiles wpane "$MAIN" --resume >/dev/null
check "$(last_start)" '-- resume --last ' 'codex resume without a record'

# A broken record is replaced, not fatal.
echo 'not json' > "$RECORD"
worker --auto
jq -e '.["worker-dotfiles"].provider == "claude"' "$RECORD" >/dev/null || fail 'broken record was not replaced'

# Starts of several agents at once all land in the record.
rm "$RECORD"
worker & "$TASK_AGENT" start researcher rpane >/dev/null 2>&1 & worker & wait
jq -e '.["worker-dotfiles"] and .researcher.cwd == $r' --arg r "$TASK/research" "$RECORD" >/dev/null ||
    fail "parallel starts lost a record: $(cat "$RECORD")"
echo 'PASS: record written on every start; --auto resumes only a matching session with a transcript'

# --- orchestrator ----------------------------------------------------------------------
rm -f "$RECORD"
(cd "$TASK" && "$TASK_AGENT" orchestrator --auto >/dev/null)
id=$(field orchestrator session_id)
check "$(cat "$FAKE_CLAUDE")" "--session-id $id" 'fresh orchestrator'
check "$(cat "$FAKE_CLAUDE")" 'Run your start-up steps now' 'fresh orchestrator kickoff'
[[ $(field orchestrator cwd) == "$TASK" ]] || fail 'orchestrator cwd is the task root'
touch "$HOME/.claude/projects/-wt/$id.jsonl"
(cd "$TASK" && "$TASK_AGENT" orchestrator --auto >/dev/null)
check "$(cat "$FAKE_CLAUDE")" "--resume $id" 'orchestrator auto resumes'
check "$(cat "$FAKE_CLAUDE")" 'You were resumed' 'resumed orchestrator kickoff'
dry=$(cd "$TASK" && "$TASK_AGENT" --dry-run orchestrator --restarted)
refute "$dry" '--resume' 'a restarted orchestrator is fresh'
check "$dry" 'session: fresh' 'restarted dry run names a fresh session'
[[ $(field orchestrator session_id) == "$id" ]] || fail 'a dry run changed the record'
echo 'PASS: the orchestrator is recorded and resumed by --auto; --restarted stays fresh'

# --- picker ---------------------------------------------------------------------------
# The task tab has no y/n prompt: the orchestrator branch only launches with --auto.
branch=$(sed -n '/TASK_ROLE:-}" == orchestrator/,/^else/p' "$PICKER")
check "$branch" 'orchestrator --auto' 'picker launches the orchestrator with --auto'
refute "$branch" 'ask_resume' 'picker asks no resume question on task tabs'
echo 'PASS: the task picker asks no resume question'

echo "task-agent session fixture: ok"
