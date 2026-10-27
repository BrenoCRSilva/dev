#!/usr/bin/env bash
# Status line for the task orchestrator: model, cost, context, prompt cache and the
# task's context repo count (ctx-repos, omitted when there are none).
# task-agent.sh wires it with --settings for the orchestrator launch only. Repo
# and researcher agents never get it, so their prompt prefix does not change.
# Input is Claude Code's status JSON on stdin. The cost is Claude Code's own
# list-price estimate, so it is labelled "est".
set -u

input=$(cat)
# Joined with "|" because tab is whitespace to read and would merge empty fields.
fields=$(jq -r '
    def text: if . == null then "" else tostring end;
    [ (.model.display_name // "model"),
      (.cost.total_cost_usd | text),
      (.context_window.used_percentage | text),
      (.prompt_cache.warm | text),
      (.prompt_cache.hit_ratio | text),
      (.prompt_cache.misses | text),
      (.prompt_cache.ttl // ""),
      (.workspace.project_dir // .cwd // "")
    ] | join("|")' <<< "$input" 2>/dev/null) && [[ -n $fields ]] ||
    { echo "orchestrator: status input unreadable"; exit 0; }
IFS='|' read -r model cost used warm hit misses ttl root <<< "$fields"

money='cost -'
[[ -n $cost ]] && money=$(printf 'cost $%.2f est' "$cost")
context='ctx -'
[[ -n $used ]] && context=$(printf 'ctx %.0f%%' "$used")
cache='cache -'
if [[ -n $warm ]]; then
    state=cold
    [[ $warm == true ]] && state=warm
    cache="cache $state"
    [[ -n $hit ]] && cache+=$(awk -v h="$hit" 'BEGIN { printf ", hit %.0f%%", h * 100 }')
    [[ -n $misses ]] && cache+=", misses $misses"
    [[ -n $ttl ]] && cache+=" ($ttl)"
fi
# C7: the task's context repo count from its records file; no git calls here.
repos=''
if [[ -n $root && -f $root/.task-context.tsv ]]; then
    n=$(grep -c . "$root/.task-context.tsv")
    (( n > 0 )) && repos=" | ctx-repos: $n"
fi
printf 'orchestrator | %s | %s | %s | %s%s\n' "$model" "$money" "$context" "$cache" "$repos"
