#!/usr/bin/env bash
# Offline checks for `task-agent.sh stop` (M4a item 3): /exit ends an idle agent, the background-work confirm
# gets one Enter, the autocompact dialog gets "Keep auto" (up, enter) and one more /exit, a dialog that never
# clears leaves the agent running with one Enter, and a working agent is refused without --force. A fake herdr
# keeps the pending dialog in a file and shows it through `agent read`. Writes only inside a temporary folder.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TASK_AGENT="$ROOT/env/.config/tmux/scripts/task-agent.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home"
# Fake herdr. FAKE_DIALOG names the dialog the first /exit raises: background, compact, background-stuck or empty.
# `agent get` answers until the agent is gone; an /exit with nothing pending ends it; Enter ends a background
# confirm (never for background-stuck); "up enter" picks Keep auto; the second /exit then ends the agent.
cat > "$TMP/bin/herdr" <<'STUB'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
pending=$(cat "$FAKE_STATE/pending" 2>/dev/null || true)
case "$*" in
    "agent get worker-dotfiles")
        [[ -e "$FAKE_STATE/gone" ]] && exit 1
        printf '{"result":{"agent":{"agent_status":"%s","pane_id":"w2:p1"}}}\n' "$(cat "$FAKE_STATE/status")" ;;
    "agent prompt worker-dotfiles /exit")
        if [[ ! -e "$FAKE_STATE/shown" ]]; then
            touch "$FAKE_STATE/shown"
            if [[ -n "${FAKE_DIALOG:-}" ]]; then printf '%s' "$FAKE_DIALOG" > "$FAKE_STATE/pending"; else touch "$FAKE_STATE/gone"; fi
        elif [[ -z "$pending" ]]; then
            touch "$FAKE_STATE/gone"
        fi ;;
    "agent read worker-dotfiles --source visible")
        case "$pending" in
            background|background-stuck) echo "Background work is running. Exit anyway?" ;;
            compact) echo "We recommend compacting earlier. Keep auto / Compact now" ;;
            *) echo "> " ;;
        esac ;;
    "agent send-keys worker-dotfiles enter")
        if [[ "$pending" == background ]]; then rm -f "$FAKE_STATE/pending"; touch "$FAKE_STATE/gone"; fi ;;
    "agent send-keys worker-dotfiles up enter")
        [[ "$pending" == compact ]] && rm -f "$FAKE_STATE/pending" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/herdr"

export PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/calls.log" HOME="$TMP/home" XDG_STATE_HOME="$TMP/xdg"
unset TASK_SESSION TASK_PROVIDER

fail() { echo "stop fixture: FAIL: $*" >&2; exit 1; }
check() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }
count() { grep -cFx "$1" "$FAKE_LOG" || true; }

# run_stop <dialog> <status> [flags...]: a fresh fake session, then one stop. Sets out and code.
run_stop() {
    local dialog=$1 status=$2
    shift 2
    export FAKE_STATE="$TMP/state-$RANDOM$RANDOM" FAKE_DIALOG=$dialog
    mkdir -p "$FAKE_STATE"
    printf '%s' "$status" > "$FAKE_STATE/status"
    : > "$FAKE_LOG"
    code=0
    out=$("$TASK_AGENT" stop worker-dotfiles "$@" 2>&1) || code=$?
}

# --- an idle agent that exits on the first /exit ------------------------------
run_stop "" idle
[[ $code -eq 0 ]] || fail "plain stop exited $code: $out"
check "$out" 'stopped worker-dotfiles' 'plain stop reports it'
[[ $(count 'agent prompt worker-dotfiles /exit') -eq 1 ]] || fail "plain stop sent /exit more than once"
[[ $(count 'agent send-keys worker-dotfiles enter') -eq 0 ]] || fail "plain stop pressed Enter"

# --- the background-work confirm: one Enter ---------------------------------
run_stop background idle
[[ $code -eq 0 ]] || fail "background confirm stop exited $code: $out"
check "$out" 'stopped worker-dotfiles' 'background confirm: stopped'
[[ $(count 'agent send-keys worker-dotfiles enter') -eq 1 ]] || fail "background confirm: Enter must be sent once"
[[ $(count 'agent send-keys worker-dotfiles up enter') -eq 0 ]] || fail "background confirm: no autocompact keys"

# --- the autocompact dialog eats /exit: Keep auto, then /exit again ------------
run_stop compact idle
[[ $code -eq 0 ]] || fail "autocompact stop exited $code: $out"
check "$out" 'stopped worker-dotfiles' 'autocompact: stopped'
[[ $(count 'agent send-keys worker-dotfiles up enter') -eq 1 ]] || fail "autocompact: Keep auto (up, enter) must be sent once"
[[ $(count 'agent prompt worker-dotfiles /exit') -eq 2 ]] || fail "autocompact: /exit must be retried once after Keep auto"

# --- a confirm that never clears: bounded, Enter once, reported ---------------
run_stop background-stuck idle
[[ $code -eq 1 ]] || fail "stuck confirm exited $code, expected 1: $out"
check "$out" 'still running after /exit; left as it is' 'stuck confirm: reported'
[[ $(count 'agent send-keys worker-dotfiles enter') -eq 1 ]] || fail "stuck confirm: Enter must still be sent once"
[[ $(count 'agent prompt worker-dotfiles /exit') -eq 1 ]] || fail "stuck confirm: /exit must not be resent"

# --- a working agent is refused without --force, and --force skips only that check ---
run_stop "" working
[[ $code -eq 1 ]] || fail "working agent stop exited $code, expected 1"
check "$out" 'is working; wait for it, or stop worker-dotfiles --force' 'working agent: refused'
[[ $(count 'agent prompt worker-dotfiles /exit') -eq 0 ]] || fail "working agent: /exit must not be sent"
run_stop "" working --force
[[ $code -eq 0 ]] || fail "--force stop exited $code: $out"
check "$out" 'stopped worker-dotfiles' '--force: stopped'

echo "task-agent stop fixture: ok"
