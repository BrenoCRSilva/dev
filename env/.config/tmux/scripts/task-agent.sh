#!/usr/bin/env bash
# Launch a task's agents with their role prompt, model and effort; the only
# place these are set.
#
#   task-agent.sh [--dry-run] [--provider claude|codex] orchestrator [--resume]
#   task-agent.sh [--dry-run] [--provider claude|codex] start repo <name> <pane_id> <canonical_repo> [--resume]
#   task-agent.sh [--dry-run] [--provider claude|codex] start researcher <pane_id> [--resume]
#   task-agent.sh [--dry-run] stop <name> [--force]
#
# The researcher is started on demand, not at task creation. stop sends /exit
# to a finished worker or researcher; a working agent needs --force. Repo agents
# also get codegraph (MCP code index) and ponytail (minimal-code rules); each is
# skipped with a warning when it is missing, and no other role gets them.
# The provider defaults to $TASK_PROVIDER, else claude. Launching the
# orchestrator exports TASK_PROVIDER so the agents it starts follow it.
# --dry-run prints the command instead of running it. --resume must be the
# last argument.
set -euo pipefail

ROLES_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/task-roles"

declare -A MODEL=(
    [claude:orchestrator]=claude-opus-5-5 [claude:repo]=claude-haiku-5-5 [claude:researcher]=claude-haiku-5-5
    [codex:orchestrator]=gpt-6-astra      [codex:repo]=gpt-6-luna         [codex:researcher]=gpt-6-luna
)
declare -A EFFORT=(
    [claude:orchestrator]=medium [claude:repo]=high [claude:researcher]=high
    [codex:orchestrator]=medium  [codex:repo]=high  [codex:researcher]=medium
)
declare -A PROMPT=([orchestrator]=orchestrator.md [repo]=repo-agent.md [researcher]=researcher.md)

# ponytail is pinned to a tag and checked out outside any repo. Its Claude
# plugin loads with --plugin-dir; its hooks are passed to codex with -c. For
# codex, PLUGIN_DATA keeps ponytail's state out of ~/.claude. Claude's own
# ponytail state still goes to ~/.claude: its config dir cannot move without
# moving Claude's credentials and settings too.
PONYTAIL_VERSION=5.2.0
PONYTAIL_DIR="$HOME/.local/share/ponytail/v$PONYTAIL_VERSION"
PONYTAIL_STATE="$HOME/.local/state/ponytail/codex"

# --- arguments -------------------------------------------------------------
usage() {
    cat >&2 <<'EOF'
usage: task-agent.sh [--dry-run] [--provider claude|codex] orchestrator [--resume]
       task-agent.sh [--dry-run] [--provider claude|codex] start repo <name> <pane_id> <canonical_repo> [--resume]
       task-agent.sh [--dry-run] [--provider claude|codex] start researcher <pane_id> [--resume]
       task-agent.sh [--dry-run] stop <name> [--force]
EOF
    exit 2
}

# --- stop ---------------------------------------------------------------------
# TASK_SESSION names the herdr session that holds the agent; task-sessionizer
# sets it. Unset, herdr uses its current session.
herdr_cmd() {
    if [[ -n "${TASK_SESSION:-}" ]]; then
        herdr --session "$TASK_SESSION" "$@"
    else
        herdr "$@"
    fi
}

# Ends a worker or researcher agent by sending it /exit, as if typed. An agent
# that is working is left alone unless --force is given. Nothing is killed: if
# the agent is still there after the wait, that is reported.
stop_agent() {
    local dry=$1 name=${2:-} arg info state pane force=no
    [[ -n "$name" ]] || usage
    for arg in "${@:3}"; do
        [[ "$arg" == --force ]] || usage
        force=yes
    done
    command -v jq >/dev/null || { echo "task-agent: jq is required to stop an agent" >&2; exit 1; }
    info=$(herdr_cmd agent get "$name" 2>/dev/null) || { echo "task-agent: no agent named $name" >&2; exit 1; }
    state=$(jq -r '.result.agent.agent_status' <<< "$info")
    pane=$(jq -r '.result.agent.pane_id' <<< "$info")
    if [[ "$state" == working && "$force" != yes ]]; then
        echo "task-agent: $name is working; wait for it, or stop $name --force" >&2
        exit 1
    fi
    if [[ "$dry" == yes ]]; then
        printf 'would send /exit to %s (pane %s, status %s)\n' "$name" "$pane" "$state"
        return 0
    fi
    herdr_cmd agent prompt "$name" /exit >/dev/null
    for _ in $(seq 1 40); do
        herdr_cmd agent get "$name" >/dev/null 2>&1 || { printf 'stopped %s\n' "$name"; return 0; }
        sleep 0.5
    done
    echo "task-agent: $name is still running after /exit; left as it is" >&2
    return 1
}

dry_run=no
if [[ "${1:-}" == --dry-run ]]; then dry_run=yes; shift; fi

if [[ "${1:-}" == stop ]]; then
    stop_agent "$dry_run" "${@:2}"
    exit
fi

provider=${TASK_PROVIDER:-claude}
if [[ "${1:-}" == --provider ]]; then
    (( $# >= 2 )) || usage
    provider=$2
    shift 2
fi
case "$provider" in
    claude|codex) ;;
    *) usage ;;
esac

resume=no
if (( $# > 0 )) && [[ "${!#}" == --resume ]]; then
    resume=yes
    set -- "${@:1:$#-1}"
fi

role='' name='' pane='' canonical_repo=''
case "${1:-}" in
    orchestrator)
        (( $# == 1 )) || usage
        role=orchestrator ;;
    start)
        (( $# >= 2 )) || usage
        case "$2" in
            repo)
                (( $# == 5 )) && [[ -n "$3" && -n "$4" && -n "$5" ]] || usage
                role=repo name=$3 pane=$4 canonical_repo=$5
                canonical_repo=$(realpath -e "$canonical_repo") || { echo "task-agent: canonical repo does not exist" >&2; exit 1; }
                [[ -d "$canonical_repo/.git" ]] || { echo "task-agent: expected a canonical git checkout with a .git directory: $canonical_repo" >&2; exit 1; }
                ;;
            researcher)
                (( $# == 3 )) && [[ -n "$3" ]] || usage
                role=researcher name=researcher pane=$3
                ;;
            *) usage ;;
        esac
        ;;
    *) usage ;;
esac

# --- command ---------------------------------------------------------------
# Adds the repo-only tools to ARGS for the provider. A missing tool is reported
# on stderr and left out, so the agent still starts. Paths that go into the
# codex hook command or TOML are limited to safe characters, since they are not
# quoted for the shell or TOML.
safe_path() { [[ "$1" =~ ^[A-Za-z0-9_./-]+$ ]]; }

repo_tool_args() {
    local provider=$1 codegraph=no ponytail=no cmd
    if command -v codegraph >/dev/null 2>&1; then
        codegraph=yes
    else
        echo "task-agent: codegraph is not on PATH; repo agent starts without it" >&2
    fi
    if [[ -f "$PONYTAIL_DIR/.claude-plugin/plugin.json" && -f "$PONYTAIL_DIR/hooks/ponytail-activate.js" ]] &&
        safe_path "$PONYTAIL_DIR" && safe_path "$PONYTAIL_STATE" && command -v node >/dev/null 2>&1; then
        ponytail=yes
    else
        echo "task-agent: ponytail $PONYTAIL_VERSION is not usable at $PONYTAIL_DIR (missing checkout, unsafe path or no node); repo agent starts without it" >&2
    fi

    if [[ $provider == claude ]]; then
        ARGS+=(--settings "$ROLES_DIR/repo-agent.claude-settings.json")
        if [[ $codegraph == yes ]]; then
            ARGS+=(--mcp-config "$ROLES_DIR/repo-agent.mcp.json" --allowedTools 'mcp__codegraph__*')
        fi
        if [[ $ponytail == yes ]]; then ARGS+=(--plugin-dir "$PONYTAIL_DIR"); fi
        return
    fi

    if [[ $codegraph == yes ]]; then
        ARGS+=(-c 'mcp_servers.codegraph.command="codegraph"'
               -c 'mcp_servers.codegraph.args=["serve","--mcp"]'
               -c 'mcp_servers.codegraph.env={CODEGRAPH_TELEMETRY="0"}')
    fi
    if [[ $ponytail == yes ]]; then
        cmd="env PLUGIN_DATA=$PONYTAIL_STATE node $PONYTAIL_DIR/hooks"
        ARGS+=(
            -c "hooks.SessionStart=[{matcher=\"startup|resume|clear|compact\",hooks=[{type=\"command\",command=\"$cmd/ponytail-activate.js\",timeout=5}]}]"
            -c "hooks.SubagentStart=[{hooks=[{type=\"command\",command=\"$cmd/ponytail-subagent.js\",timeout=5}]}]"
            -c "hooks.UserPromptSubmit=[{hooks=[{type=\"command\",command=\"$cmd/ponytail-mode-tracker.js\",timeout=5}]}]"
        )
    fi
}

# Fills ARGS with the role's model, effort and prompt for the provider. A dry
# run shows codex's prompt as a placeholder instead of its contents.
# herdr refuses agent arguments containing newlines, so no argument may be multi-line: claude reads the prompt from its file, codex gets it JSON-escaped on one line.
ARGS=()
agent_args() {
    local role=$1 want_resume=$2 file prompt
    file="$ROLES_DIR/${PROMPT[$role]}"
    [[ -f "$file" ]] || { echo "task-agent: missing $file" >&2; exit 1; }
    if [[ $provider == claude ]]; then
        ARGS=(--model "${MODEL[claude:$role]}" --effort "${EFFORT[claude:$role]}" --append-system-prompt-file "$file")
        if [[ $role == repo ]]; then
            repo_tool_args claude
            ARGS+=(--permission-mode auto --add-dir "$canonical_repo/.git")
        elif [[ $role == researcher ]]; then
            ARGS+=(--permission-mode auto)
        fi
        if [[ $want_resume == yes ]]; then ARGS+=(--continue); fi
    else
        if [[ $dry_run == yes ]]; then
            prompt="\"<prompt:${PROMPT[$role]}>\""
        else
            prompt=$(python3 -I -c 'import json, sys; print(json.dumps(sys.stdin.read()))' < "$file")
        fi
        ARGS=()
        if [[ $want_resume == yes ]]; then ARGS=(resume --last); fi
        ARGS+=(-m "${MODEL[codex:$role]}" -c "model_reasoning_effort=\"${EFFORT[codex:$role]}\"" -c "developer_instructions=$prompt")
        # Codex's closest match to Claude's auto mode: the model decides when to
        # ask (on-request), inside the same workspace-write sandbox as before.
        if [[ $role == repo ]]; then
            repo_tool_args codex
            ARGS+=(-a on-request -s workspace-write --add-dir "$canonical_repo/.git")
        fi
        if [[ $role == researcher ]]; then ARGS+=(-a on-request -s workspace-write); fi
    fi
}

# Claude asks once per directory whether to trust it, which stalls an unattended
# start. Before a repo or researcher agent starts in its pane, mark the pane's
# cwd trusted in ~/.claude.json. Only projects[<cwd>].hasTrustDialogAccepted is
# set; the file is replaced through a temp file and mv, so other keys and other
# sessions' entries are kept.
trust_pane_cwd() {
    local cfg="$HOME/.claude.json" cwd tmp state
    # jq program: $p is jq's variable (passed by --arg), not a shell expansion.
    # shellcheck disable=SC2016
    local filter='.projects //= {} | .projects[$p] //= {} | .projects[$p].hasTrustDialogAccepted = true'
    cwd=$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.cwd // empty' 2>/dev/null) || cwd=
    if [[ -z "$cwd" ]]; then
        if [[ $dry_run == yes ]]; then
            echo "trust: cannot read the cwd of pane $pane (herdr lookup failed); nothing to mark"
            return 0
        fi
        echo "task-agent: cannot read the cwd of pane $pane; not starting without its trust set" >&2
        exit 1
    fi
    cwd=$(realpath -e "$cwd") || { echo "task-agent: pane cwd does not exist: $cwd" >&2; exit 1; }

    if [[ -f $cfg ]]; then
        state=$(jq -r --arg p "$cwd" '(.projects[$p] // {}) | .hasTrustDialogAccepted | tostring' "$cfg")
    else
        state=missing-file
    fi
    if [[ $state == true ]]; then
        echo "trust: $cwd is already trusted in $cfg"
        return 0
    fi
    if [[ $dry_run == yes ]]; then
        echo "trust: would set projects[\"$cwd\"].hasTrustDialogAccepted = true in $cfg (currently: $state)"
        return 0
    fi

    tmp=$(mktemp "$cfg.XXXXXX")
    if [[ $state == missing-file ]]; then
        printf '{}\n' | jq --arg p "$cwd" "$filter" > "$tmp" || { rm -f "$tmp"; exit 1; }
    else
        chmod --reference="$cfg" "$tmp"
        jq --arg p "$cwd" "$filter" "$cfg" > "$tmp" || { rm -f "$tmp"; exit 1; }
    fi
    mv -f "$tmp" "$cfg"
    echo "trust: marked $cwd trusted in $cfg (was: $state)"
}

agent_args "$role" "$resume"

if [[ $role == orchestrator ]]; then
    if [[ $resume == yes ]]; then
        kickoff="You were resumed as this task's orchestrator. Run your start-up steps again, then tell me where the plan stands."
    else
        kickoff="You are this task's orchestrator. Run your start-up steps now."
    fi
    export TASK_PROVIDER=$provider
    cmd=("$provider" "${ARGS[@]}" "$kickoff")
else
    if [[ $provider == claude ]]; then trust_pane_cwd; fi
    cmd=(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 60000 -- "${ARGS[@]}")
fi

if [[ $dry_run == yes ]]; then
    printf '%q ' "${cmd[@]}"
    printf '\n'
    exit 0
fi

"${cmd[@]}"
