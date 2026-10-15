#!/usr/bin/env bash
# Fixture for the orchestrator status line: sample status JSON in, line out. Also
# checks that the orchestrator settings file points at the executable script.
# The "$" in the expected lines is literal text, hence the SC2016 directive.
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATUS="$ROOT/env/.config/tmux/scripts/task-statusline.sh"
SETTINGS="$ROOT/env/.config/tmux/scripts/task-roles/orchestrator.claude-settings.json"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
line() { printf '%s' "$1" | "$STATUS"; }

full=$(line '{"model":{"display_name":"Opus 5.5"},"cost":{"total_cost_usd":1.2345},"context_window":{"used_percentage":42.3},"prompt_cache":{"warm":true,"hit_ratio":0.96,"misses":0,"ttl":"1h"}}')
[[ "$full" == 'orchestrator | Opus 5.5 | cost $1.23 est | ctx 42% | cache warm, hit 96%, misses 0 (1h)' ]] ||
    fail "full status line: $full"

# Before the first response there is no context percentage and no prompt_cache.
start=$(line '{"model":{"display_name":"Haiku 5.5"},"cost":{"total_cost_usd":0},"context_window":{"used_percentage":null}}')
[[ "$start" == 'orchestrator | Haiku 5.5 | cost $0.00 est | ctx - | cache -' ]] || fail "start status line: $start"

cold=$(line '{"model":{"display_name":"Opus 5.5"},"cost":{"total_cost_usd":3},"context_window":{"used_percentage":77.6},"prompt_cache":{"warm":false,"hit_ratio":null,"misses":2,"ttl":"5m"}}')
[[ "$cold" == 'orchestrator | Opus 5.5 | cost $3.00 est | ctx 78% | cache cold, misses 2 (5m)' ]] || fail "cold status line: $cold"

for bad in 'not json' ''; do
    [[ "$(line "$bad")" == 'orchestrator: status input unreadable' ]] || fail "bad input '$bad' not reported"
done

[[ -x "$STATUS" ]] || fail 'task-statusline.sh is not executable'
[[ $(jq -r '.statusLine.type' "$SETTINGS") == command ]] || fail 'orchestrator settings lack a command status line'
command=$(jq -r '.statusLine.command' "$SETTINGS")
[[ "$(basename "$command")" == task-statusline.sh ]] || fail "orchestrator settings point at $command"

printf 'PASS: status line renders full, pre-response, cold-cache and unreadable input; settings point at it\n'
