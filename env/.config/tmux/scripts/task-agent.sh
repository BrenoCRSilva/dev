#!/usr/bin/env bash
# Launch a task's agents with their role prompt, model and effort; the only
# place these are set.
#
#   task-agent.sh [--dry-run] [--provider claude|codex] orchestrator [--resume]
#   task-agent.sh [--dry-run] [--provider claude|codex] start repo <name> <pane_id> <canonical_repo> [--resume]
#   task-agent.sh [--dry-run] [--provider claude|codex] start researcher <pane_id> [--resume]
#
# The provider defaults to $TASK_PROVIDER, else claude. Launching the
# orchestrator exports TASK_PROVIDER so the agents it starts follow it.
# --dry-run prints the command instead of running it. --resume must be the
# last argument.
set -euo pipefail

ROLES_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/task-roles"

declare -A MODEL=(
    [claude:orchestrator]=claude-opus-5-5 [claude:repo]=claude-haiku-5-5 [claude:researcher]=claude-sonnet-5-5
    [codex:orchestrator]=gpt-6-astra      [codex:repo]=gpt-6-luna         [codex:researcher]=gpt-6-luna
)
declare -A EFFORT=([orchestrator]=medium [repo]=high [researcher]=medium)
declare -A PROMPT=([orchestrator]=orchestrator.md [repo]=repo-agent.md [researcher]=researcher.md)

# --- arguments -------------------------------------------------------------
usage() {
    cat >&2 <<'EOF'
usage: task-agent.sh [--dry-run] [--provider claude|codex] orchestrator [--resume]
       task-agent.sh [--dry-run] [--provider claude|codex] start repo <name> <pane_id> <canonical_repo> [--resume]
       task-agent.sh [--dry-run] [--provider claude|codex] start researcher <pane_id> [--resume]
EOF
    exit 2
}

dry_run=no
if [[ "${1:-}" == --dry-run ]]; then dry_run=yes; shift; fi

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
# Fills ARGS with the role's model, effort and prompt for the provider. A dry
# run shows codex's prompt as a placeholder instead of its contents.
# herdr refuses agent arguments containing newlines, so no argument may be multi-line: claude reads the prompt from its file, codex gets it JSON-escaped on one line.
ARGS=()
agent_args() {
    local role=$1 want_resume=$2 file prompt
    file="$ROLES_DIR/${PROMPT[$role]}"
    [[ -f "$file" ]] || { echo "task-agent: missing $file" >&2; exit 1; }
    if [[ $provider == claude ]]; then
        ARGS=(--model "${MODEL[claude:$role]}" --effort "${EFFORT[$role]}" --append-system-prompt-file "$file")
        if [[ $role == repo ]]; then
            ARGS+=(--permission-mode acceptEdits --add-dir "$canonical_repo/.git")
        elif [[ $role == researcher ]]; then
            ARGS+=(--permission-mode acceptEdits)
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
        ARGS+=(-m "${MODEL[codex:$role]}" -c "model_reasoning_effort=\"${EFFORT[$role]}\"" -c "developer_instructions=$prompt")
        if [[ $role == repo ]]; then ARGS+=(-s workspace-write --add-dir "$canonical_repo/.git"); fi
        if [[ $role == researcher ]]; then ARGS+=(-s workspace-write); fi
    fi
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
    cmd=(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 60000 -- "${ARGS[@]}")
fi

if [[ $dry_run == yes ]]; then
    printf '%q ' "${cmd[@]}"
    printf '\n'
    exit 0
fi

"${cmd[@]}"
