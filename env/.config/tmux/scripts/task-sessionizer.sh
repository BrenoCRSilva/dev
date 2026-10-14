#!/usr/bin/env bash
# Task-scoped tmux sessionizer. A task is ~/tasks/<task>/ holding one git
# worktree per repo, all on the same branch; the tmux session is scoped to it.
#
#   task-sessionizer.sh                      fzf picker: tasks and repos
#   task-sessionizer.sh popup                same, in the Omarchy menu (keybind)
#   task-sessionizer.sh sessions             session manager in the terminal
#                                            (Super+S uses the pontual.tasks shell plugin)
#   task-sessionizer.sh add <task> [repo..]  add repos (picker when none given)
#   task-sessionizer.sh rm <task> [--force]  remove worktrees, dir and session
#
# Picking a task opens it; picking a repo starts a new task from it.
# Deps: git, tmux, fzf, fd (popup mode also uses omarchy-menu-*).

TASKS_DIR="${TASKS_DIR:-$HOME/tasks}"
REPO_ROOTS=("$HOME/Projects" "$HOME/Work")
BASE_PORT=20000
SELF=$(realpath "$0")
AGENT_PICKER="$HOME/.config/tmux/scripts/agent-picker.sh"

ICON_TASK=$''
ICON_REPO=$''
ICON_ADD=$''
ICON_DONE=$''
ADD_LABEL="Add repos to a task"

# Worktrees created in this run whose post-create hook still has to run.
PENDING=()
# Repos added in this run, announced to a running orchestrator.
NEW_REPOS=()

die() {
    echo "error: $*" >&2
    [[ -n "${TASK_POPUP:-}" ]] && notify-send "Task sessionizer" "$*"
    exit 1
}

# Repos are dirs holding a .git *directory*; worktrees (.git file) are skipped.
list_repos() {
    fd -H -I -t d -d 3 '^\.git$' "${REPO_ROOTS[@]}" 2>/dev/null | sed 's#/\.git/\{0,1\}$##' | sort
}

list_tasks() {
    [[ -d "$TASKS_DIR" ]] || return 0
    find "$TASKS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

task_worktrees() {
    local d
    for d in "$TASKS_DIR/$1"/*/; do
        [[ -e "${d}.git" ]] && echo "${d%/}"
    done
}

# "api, web on feat-x", prefixed with "running" when its session is up.
task_detail() {
    local wt names="" branch=""
    while IFS= read -r wt; do
        names+="${names:+, }$(basename "$wt")"
        [[ -n "$branch" ]] || branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    done < <(task_worktrees "$1")
    names="$names on ${branch:-?}"
    tmux has-session -t "=$(session_name "$1")" 2>/dev/null && names="running, $names"
    echo "$names"
}

origin_repo() {
    dirname "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
}

session_name() { echo "${1//[.:]/_}"; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# --- post-create hook --------------------------------------------------------

copy_env_files() {
    local repo=$1 wt=$2 f
    git -C "$repo" ls-files --others --directory 2>/dev/null |
        grep -E '(^|/)\.env[^/]*$' | grep -v '\.bak' |
        while IFS= read -r f; do
            [[ -f "$repo/$f" && ! -e "$wt/$f" ]] || continue
            mkdir -p "$(dirname "$wt/$f")"
            cp "$repo/$f" "$wt/$f" && echo "  env: copied $f"
        done
}

# Deterministic port per <task>/<repo>, written to every untracked env file
# that already defines PORT=.
assign_port() {
    local task=$1 name=$2 wt=$3 hash port f i=0
    hash=$(printf '%s' "$task/$name" | cksum | cut -d' ' -f1)
    while IFS= read -r f; do
        grep -q '^PORT=' "$wt/$f" 2>/dev/null || continue
        port=$((BASE_PORT + hash % 10000 + i))
        sed -i "s/^PORT=.*/PORT=$port/" "$wt/$f"
        echo "  port: $port -> $f"
        i=$((i + 1))
    done < <(git -C "$wt" ls-files --others --directory 2>/dev/null | grep -E '(^|/)\.env[^/]*$')
    [[ $i -gt 0 ]] || echo "  port: no PORT= in $name's env files, skipped"
}

install_deps() {
    local wt=$1 cmd=()
    if [[ -f "$wt/pnpm-lock.yaml" ]]; then cmd=(pnpm install)
    elif [[ -f "$wt/yarn.lock" ]]; then cmd=(yarn install)
    elif [[ -f "$wt/bun.lock" || -f "$wt/bun.lockb" ]]; then cmd=(bun install)
    elif [[ -f "$wt/package-lock.json" ]]; then cmd=(npm install)
    elif [[ -f "$wt/go.mod" ]]; then cmd=(go mod download)
    else return 0
    fi
    if ! command -v "${cmd[0]}" >/dev/null; then
        echo "  deps: ${cmd[0]} not installed, skipped '${cmd[*]}'"
        return 0
    fi
    echo "  deps: ${cmd[*]}"
    (cd "$wt" && "${cmd[@]}") || echo "  deps: '${cmd[*]}' failed"
}

run_hook() {
    local task=$1 name=$2 wt repo
    wt="$TASKS_DIR/$task/$name"
    [[ -e "$wt/.git" ]] || die "no worktree $name in task $task"
    repo=$(origin_repo "$wt")
    echo "$name: post-create"
    if [[ -x "$repo/.task-hook" ]]; then
        echo "  hook: $repo/.task-hook"
        (cd "$wt" && TASK="$task" ORIGIN_REPO="$repo" "$repo/.task-hook")
        return
    fi
    copy_env_files "$repo" "$wt"
    assign_port "$task" "$name" "$wt"
    install_deps "$wt"
}

# Run pending hooks in the task's server windows when its session is up (so a
# slow install is visible and doesn't block the picker), else right here.
dispatch_hooks() {
    local task=$1 s name win
    s=$(session_name "$task")
    for name in "${PENDING[@]}"; do
        if tmux has-session -t "=$s" 2>/dev/null; then
            win="srv-$name"
            tmux list-windows -t "=$s" -F '#W' | grep -qx "$win" || win=srv-1
            tmux send-keys -t "=$s:$win" "$(printf '%q hook %q %q' "$SELF" "$task" "$name")" Enter
        else
            run_hook "$task" "$name"
        fi
    done
    PENDING=()
}

# --- task creation -----------------------------------------------------------

add_repo() {
    local task=$1 branch=$2 repo=${3%/} name wt
    name=$(basename "$repo")
    wt="$TASKS_DIR/$task/$name"
    [[ -d "$repo/.git" ]] || { echo "skip $repo: not a git checkout"; return 1; }
    [[ -e "$wt" ]] && { echo "$name: already in $task"; return 0; }
    mkdir -p "$TASKS_DIR/$task"
    echo "$name: worktree on $branch"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" ||
        [[ -n "$(git -C "$repo" for-each-ref "refs/remotes/*/$branch")" ]]; then
        git -C "$repo" worktree add "$wt" "$branch" || return 1
    else
        git -C "$repo" worktree add -b "$branch" "$wt" || return 1
    fi
    PENDING+=("$name")
    NEW_REPOS+=("$name")
    # Keep a running task session in sync with its repo worktrees.
    tmux has-session -t "=$(session_name "$task")" 2>/dev/null &&
        ensure_task_layout "$task"
}

write_agents_md() {
    local task=$1 branch=$2 file="$TASKS_DIR/$1/AGENTS.md" wt
    write_claude_files "$task"
    [[ -e "$file" ]] && return 0
    {
        printf '# %s\n\n## Goal\n\n## Repos\n' "$task"
        while IFS= read -r wt; do
            printf -- '- %s: (role in this task; the orchestrator fills this in)\n' "$(basename "$wt")"
        done < <(task_worktrees "$task")
        cat <<EOF

## Agents
| name | role | model / effort | herdr workspace |
|---|---|---|---|

## Cross-repo contracts
(Shared endpoints, payload shapes, file formats and names that repos depend on, numbered C1, C2, …)

## Plan / status
(Numbered steps, one owner repo each, with checks; [checkpoint] marks where the user gets a report.)

## Notes for agents
- Each repo subfolder is a git worktree on branch $branch. Work only inside your own subfolder; the orchestrator works at the task root.
- Don't \`git checkout\` other branches; use the existing worktrees.
- Each agent's role comes from its launch prompt (~/.config/tmux/scripts/task-roles/). This file holds only the task's shared state; only the orchestrator edits it.
EOF
    } > "$file"
}

CLAUDE_TASK_SETTINGS="{
  \"permissions\": {
    \"allow\": [
      \"Bash(herdr:*)\",
      \"Bash(~/.config/tmux/scripts/task-agent.sh:*)\",
      \"Bash($HOME/.config/tmux/scripts/task-agent.sh:*)\"
    ]
  }
}"

# Written by earlier versions of this script; remove_task still cleans it up.
CLAUDE_TASK_SETTINGS_OLD='{
  "permissions": {
    "allow": ["Bash(herdr:*)"]
  }
}'

# Claude Code reads CLAUDE.md, not AGENTS.md. A symlink (rather than an
# @AGENTS.md import) means repo agents pick it up from the parent folder
# without the "external import" approval. The settings let the orchestrator
# run herdr and task-agent.sh without asking.
write_claude_files() {
    local dir="$TASKS_DIR/$1"
    [[ -e "$dir/CLAUDE.md" || -L "$dir/CLAUDE.md" ]] || ln -s AGENTS.md "$dir/CLAUDE.md"
    if [[ ! -e "$dir/.claude/settings.json" ]]; then
        mkdir -p "$dir/.claude"
        printf '%s\n' "$CLAUDE_TASK_SETTINGS" > "$dir/.claude/settings.json"
    fi
}

# add_repos <task> <branch-or-empty> <repo>...
# An existing task keeps its branch; a new one defaults to the task name.
add_repos() {
    local task=$1 branch=$2 first r
    shift 2
    valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
    [[ $# -gt 0 ]] || return 1

    first=$(task_worktrees "$task" | head -n1)
    if [[ -n "$first" ]]; then
        branch=$(git -C "$first" branch --show-current)
    fi
    branch=${branch:-$task}

    for r in "$@"; do
        add_repo "$task" "$branch" "$r"
    done

    if [[ -z "$(task_worktrees "$task")" ]]; then
        rmdir "$TASKS_DIR/$task" 2>/dev/null
        die "no worktree could be created for $task"
    fi
    write_agents_md "$task" "$branch"
}

# --- session -----------------------------------------------------------------

preserve_window_name() {
    local s=$1 old=$2 candidate="preserved-$2" suffix=2
    while tmux list-windows -t "=$s" -F '#W' | grep -Fxq "$candidate"; do
        candidate="preserved-$2-$suffix"
        suffix=$((suffix + 1))
    done
    tmux rename-window -t "=$s:$old" "$candidate"
}

ensure_task_window() {
    local task=$1 s=$2 kind=$3 name=$4 cwd=$5 current_cwd current_cmd
    if tmux list-windows -t "=$s" -F '#W' | grep -Fxq "$name"; then
        current_cwd=$(tmux display-message -p -t "=$s:$name" '#{pane_current_path}')
        current_cmd=$(tmux display-message -p -t "=$s:$name" '#{pane_current_command}')
        if [[ "$current_cwd" == "$cwd" ]] && {
            [[ "$kind" == nvim ]] ||
            # Preserve a correctly rooted srv tab while its server/test runs.
            [[ "$kind" == shell && "$current_cmd" != nvim ]] ||
            [[ "$kind" == agent ]]
        }; then
            return 0
        fi
        # Keep existing panes and their processes intact; free the canonical
        # name so the required window can be created beside them.
        preserve_window_name "$s" "$name"
    fi

    tmux new-window -d -t "=$s:" -n "$name" -c "$cwd"
    if [[ "$kind" == nvim ]]; then
        tmux send-keys -t "=$s:$name" 'nvim .' Enter
    fi
}

ensure_task_layout() {
    local task=$1 s root wt name active_id current_id index=1
    local -a wts=() standard=()
    s=$(session_name "$task")
    root=$(realpath "$TASKS_DIR/$task")
    mapfile -t wts < <(task_worktrees "$task" | LC_ALL=C sort -f)
    [[ ${#wts[@]} -gt 0 ]] || die "task $task has no worktrees"

    active_id=$(tmux list-windows -t "=$s" -F '#{window_active} #{window_id}' |
        awk '$1 == "1" { print $2; exit }')
    ensure_task_window "$task" "$s" agent agent "$root"
    standard+=(agent)
    for wt in "${wts[@]}"; do
        name=$(basename "$wt")
        ensure_task_window "$task" "$s" nvim "nvim-$name" "$wt"
        standard+=("nvim-$name")
    done
    for wt in "${wts[@]}"; do
        name=$(basename "$wt")
        ensure_task_window "$task" "$s" shell "srv-$name" "$wt"
        standard+=("srv-$name")
    done

    # Swap standard windows into their canonical leading order. Extra existing
    # windows naturally move behind them and keep their panes/processes.
    for name in "${standard[@]}"; do
        current_id=$(tmux display-message -p -t "=$s:$name" '#{window_index}')
        if [[ "$current_id" != "$index" ]]; then
            tmux swap-window -d -s "=$s:$name" -t "=$s:$index"
        fi
        index=$((index + 1))
    done

    current_id=$(tmux list-windows -t "=$s" -F '#{window_active} #{window_id}' |
        awk '$1 == "1" { print $2; exit }')
    [[ "$current_id" == "$active_id" ]] || tmux select-window -t "$active_id"
}

open_session() {
    local task=$1 s created=0
    s=$(session_name "$task")
    if ! tmux has-session -t "=$s" 2>/dev/null; then
        tmux new-session -ds "$s" -n agent -c "$(realpath "$TASKS_DIR/$task")"
        tmux set-option -t "$s" @pontual_task_root "$(realpath "$TASKS_DIR/$task")"
        created=1
    fi
    ensure_task_layout "$task"
    if [[ $created == 1 ]] && command -v herdr >/dev/null; then
        herdr_layout "$task"
        tmux send-keys -t "=$s:agent" "herdr --session $s" Enter
    fi
    herdr_running "$s" && herdr_layout "$task" && herdr_announce "$task"
    dispatch_hooks "$task"
    goto_session "$s"
}

# --- herdr (agents) ----------------------------------------------------------

# Tell a running orchestrator about repos added in this run so it starts
# their agents. Silently does nothing when no orchestrator agent is up: the
# kickoff prompt covers that case when one is started.
herdr_announce() {
    local task=$1 s ws pane msg
    [[ ${#NEW_REPOS[@]} -gt 0 ]] || return 0
    msg="Added to this task just now, each with its own herdr workspace: ${NEW_REPOS[*]}. Run your start-up steps to start their agents, add them under Repos and Agents in AGENTS.md, and plan their work if the goal calls for it."
    NEW_REPOS=()
    command -v jq >/dev/null || return 0
    s=$(session_name "$task")
    herdr_running "$s" || return 0
    ws=$(herdr --session "$s" workspace list 2>/dev/null |
        jq -r --arg l "$task" '.result.workspaces[] | select(.label == $l) | .workspace_id' | head -n1)
    [[ -n "$ws" ]] || return 0
    while IFS= read -r pane; do
        herdr --session "$s" agent prompt "$pane" "$msg" >/dev/null 2>&1 && break
    done < <(herdr --session "$s" pane list 2>/dev/null |
        jq -r --arg w "$ws" '.result.panes[] | select(.workspace_id == $w) | .pane_id')
}

herdr_running() {
    command -v herdr >/dev/null && herdr session list 2>/dev/null | grep -q "^$1  *running"
}

# One persistent herdr session per task, with a workspace per repo worktree
# and one at the task root for an orchestrator agent, even with a single repo,
# plus a "report" workspace (a shell at the task root) for the reporter agent.
# Idempotent: only missing workspaces are created.
herdr_layout() {
    local task=$1 s wt label labels pane picker i wts=() want=() role=()
    s=$(session_name "$task")
    if ! herdr_running "$s"; then
        (setsid herdr --session "$s" server >/dev/null 2>&1 &)
        for i in 1 2 3 4 5 6 7 8 9 10; do
            herdr --session "$s" workspace list >/dev/null 2>&1 && break
            sleep 0.3
        done
    fi
    labels=$(herdr --session "$s" workspace list 2>/dev/null) || return 0
    labels=$(grep -o '"label":"[^"]*"' <<< "$labels")

    mapfile -t wts < <(task_worktrees "$task")
    [[ ${#wts[@]} -gt 0 ]] || return 0
    want+=("$TASKS_DIR/$task")
    want+=("${wts[@]}")
    for wt in "${want[@]}"; do
        label=$(basename "$wt")
        grep -qxF "\"label\":\"$label\"" <<< "$labels" && continue
        # The task-root workspace is the orchestrator, which starts
        # the repo agents itself, so repo panes must stay at a shell prompt.
        role=()
        picker=1
        if [[ "$wt" == "$TASKS_DIR/$task" ]]; then
            role=(--env TASK_ROLE=orchestrator)
        else
            picker=
        fi
        pane=$(herdr --session "$s" workspace create --cwd "$wt" --label "$label" "${role[@]}" --no-focus 2>/dev/null |
            grep -o '"pane_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
        # Opens on the agent picker (claude / codex / opencode).
        [[ -n "$picker" && -n "$pane" && -x "$AGENT_PICKER" ]] &&
            herdr --session "$s" pane run "$pane" "$AGENT_PICKER" >/dev/null 2>&1
    done
    # The reporter's workspace stays at a shell prompt; the orchestrator
    # starts the reporter agent in it.
    grep -qxF '"label":"report"' <<< "$labels" ||
        herdr --session "$s" workspace create --cwd "$TASKS_DIR/$task" --label report --no-focus >/dev/null 2>&1
}

# Switch to a session from wherever we are: inside tmux, a plain terminal, or
# a desktop keybind (which reuses the most recent client or opens a terminal).
goto_session() {
    local s=$1 client
    if [[ -n "${TASK_SEARCH:-}" ]]; then
        # Desktop search never steals an arbitrary existing tmux client.
        setsid uwsm-app -- xdg-terminal-exec -e tmux attach-session -t "=$s" >/dev/null 2>&1 &
    elif [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "=$s"
    elif [[ -n "${TASK_POPUP:-}" ]]; then
        client=$(tmux list-clients -F '#{client_activity} #{client_name}' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        if [[ -n "$client" ]]; then
            tmux switch-client -c "$client" -t "=$s"
        else
            setsid uwsm-app -- xdg-terminal-exec -e tmux attach-session -t "=$s" >/dev/null 2>&1 &
        fi
    else
        tmux attach-session -t "=$s"
    fi
}

# Rows for the session manager: every task (running or not), then the tmux
# sessions that are not tasks. "kind<TAB>name<TAB>detail".
session_rows() {
    local t name detail
    local -A is_task=()
    while IFS= read -r t; do
        is_task[$(session_name "$t")]=1
        printf 'task\t%s\t%s\n' "$t" "$(task_detail "$t")"
    done < <(list_tasks)
    while IFS=$'\t' read -r name detail; do
        [[ -n "${is_task[$name]:-}" ]] || printf 'session\t%s\t%s\n' "$name" "$detail"
    done < <(tmux list-sessions -F '#{session_name}'$'\t''#{?session_attached,attached,detached}, #{session_windows} windows' 2>/dev/null)
}

# Single-key yes/no; anything but y is no.
confirm() {
    local key
    printf '\n  %s [y/N] ' "$1"
    IFS= read -rsn1 key
    [[ "$key" == y || "$key" == Y ]]
}

# Session manager: no search, j/k or arrows to move, enter to open, x to
# remove (asks first), q or esc to leave.
pick_session() {
    local rows=() sel=0 n i key rest kind name detail out msg=""
    local bold=$'\e[1m' dim=$'\e[2m' rev=$'\e[7m' reset=$'\e[0m'
    trap 'printf "\e[?25h"' EXIT
    while :; do
        mapfile -t rows < <(session_rows)
        n=${#rows[@]}
        if ((n == 0)); then
            printf '\n  no tasks or sessions\n'
            sleep 1
            return
        fi
        ((sel >= n)) && sel=$((n - 1))

        printf '\e[H\e[2J\e[?25l\n  %stasks and sessions%s\n' "$bold" "$reset"
        printf '  %sj/k or arrows: move · enter: open · x: remove · q: quit%s\n\n' "$dim" "$reset"
        for ((i = 0; i < n; i++)); do
            IFS=$'\t' read -r kind name detail <<< "${rows[i]}"
            [[ "$kind" == task ]] && kind=$ICON_TASK || kind=' '
            if ((i == sel)); then
                printf '  %s %s %s %s  %s%s\n' "$rev" "$kind" "$name" "$reset" "$dim$detail" "$reset"
            else
                printf '   %s %s   %s%s\n' "$kind" "$name" "$dim$detail" "$reset"
            fi
        done
        [[ -n "$msg" ]] && printf '\n  %s\n' "$msg"
        msg=""

        IFS= read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            read -rsn2 -t 0.01 rest
            key+=$rest
        fi
        IFS=$'\t' read -r kind name detail <<< "${rows[sel]}"
        case "$key" in
            k | $'\e[A') sel=$(((sel - 1 + n) % n)) ;;
            j | $'\e[B') sel=$(((sel + 1) % n)) ;;
            '' | $'\n')
                if [[ "$kind" == task ]]; then open_session "$name"; else goto_session "$name"; fi
                return
                ;;
            x)
                if [[ "$kind" == task ]]; then
                    confirm "remove task $name? worktrees and session go, branches stay" || continue
                    if ! out=$( (TASK_POPUP=; remove_task "$name") 2>&1); then
                        if [[ "$out" == *"use --force"* ]] &&
                            confirm "${out##*error: } - discard and remove anyway?"; then
                            out=$( (TASK_POPUP=; remove_task "$name" --force) 2>&1)
                        fi
                    fi
                    msg=${out##*$'\n'}
                else
                    confirm "kill session $name?" || continue
                    tmux kill-session -t "=$name" && msg="killed session $name"
                fi
                ;;
            q | $'\e') return ;;
        esac
    done
}

# --- cleanup -----------------------------------------------------------------

remove_task() {
    local task=${1:-} force=${2:-} dir wt origin s wts=() origins=() settings
    [[ -n "$task" ]] || die "usage: rm <task> [--force]"
    dir="$TASKS_DIR/$task"
    [[ -d "$dir" ]] || die "no such task: $task"
    mapfile -t wts < <(task_worktrees "$task")

    if [[ "$force" != --force ]]; then
        for wt in "${wts[@]}"; do
            [[ -z "$(git -C "$wt" status --porcelain)" ]] ||
                die "$(basename "$wt") has uncommitted changes (use --force)"
        done
    fi

    for wt in "${wts[@]}"; do
        origin=$(origin_repo "$wt")
        origins+=("$origin")
        git -C "$origin" worktree remove ${force:+--force} "$wt" || die "could not remove $wt"
    done

    # Generated files; anything else left in the folder still blocks removal.
    [[ -L "$dir/CLAUDE.md" || "$(cat "$dir/CLAUDE.md" 2>/dev/null)" == "@AGENTS.md" ]] && rm -f "$dir/CLAUDE.md"
    rm -f "$dir/AGENTS.md"
    rm -f "$dir/REPORT.md"
    settings=$(cat "$dir/.claude/settings.json" 2>/dev/null)
    [[ "$settings" == "$CLAUDE_TASK_SETTINGS" || "$settings" == "$CLAUDE_TASK_SETTINGS_OLD" ]] && rm -f "$dir/.claude/settings.json"
    rm -f "$dir/.claude/settings.local.json"
    rmdir "$dir/.claude" 2>/dev/null
    if ! rmdir "$dir" 2>/dev/null; then
        [[ "$force" == --force ]] || die "$dir still has files (use --force)"
        rm -rf "$dir"
    fi
    for origin in "${origins[@]}"; do
        git -C "$origin" worktree prune
    done
    echo "removed task $task (branches kept)"

    s=$(session_name "$task")
    if command -v herdr >/dev/null; then
        herdr session stop "$s" >/dev/null 2>&1
        herdr session delete "$s" >/dev/null 2>&1
    fi
    tmux has-session -t "=$s" 2>/dev/null && tmux kill-session -t "=$s"
    return 0
}

# --- fzf picker (terminal / tmux prefix key) ---------------------------------

fzf_repos() {
    list_repos | sed "s#^$HOME/#~/#" |
        fzf -m --prompt "$1> " --header 'tab: mark · enter: confirm' | sed "s#^~/#$HOME/#"
}

pick() {
    local out query key task="" branch="" t r kind value repos=()
    mkdir -p "$TASKS_DIR"
    out=$({
        while IFS= read -r t; do
            printf 'task\t%s\t%s %s  (%s)\n' "$t" "$ICON_TASK" "$t" "$(task_detail "$t")"
        done < <(list_tasks)
        while IFS= read -r r; do
            printf 'repo\t%s\t%s %s  %s\n' "$r" "$ICON_REPO" "$(basename "$r")" "$(dirname "${r/#$HOME/\~}")"
        done < <(list_repos)
    } | fzf -m --delimiter '\t' --with-nth 3 --print-query --expect=ctrl-a --prompt 'task or repo> ' \
        --header $'enter: open task, or start a task from the marked repo(s)\ntab: mark repos · ctrl-a: add repos to a task · or type a new task name')
    query=$(sed -n 1p <<< "$out")
    key=$(sed -n 2p <<< "$out")
    while IFS=$'\t' read -r kind value _; do
        case "$kind" in
            task) [[ -n "$task" ]] || task=$value ;;
            repo) repos+=("$value") ;;
        esac
    done < <(sed -n '3,$p' <<< "$out")

    if [[ -n "$task" ]]; then
        if [[ "$key" == ctrl-a ]]; then
            mapfile -t repos < <(fzf_repos "add to $task")
            [[ ${#repos[@]} -gt 0 ]] && add_repos "$task" "" "${repos[@]}"
        fi
    elif [[ ${#repos[@]} -gt 0 || -n "$query" ]]; then
        task=$query
        if [[ ${#repos[@]} -gt 0 ]]; then
            read -rp "task name: " task
        else
            mapfile -t repos < <(fzf_repos "repos for $task")
        fi
        [[ -n "$task" && ${#repos[@]} -gt 0 ]] || exit 0
        valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
        if [[ ! -d "$TASKS_DIR/$task" ]]; then
            read -rp "branch [$task]: " branch
        fi
        add_repos "$task" "$branch" "${repos[@]}"
    else
        exit 0
    fi
    open_session "$task"
}

# --- Omarchy menu picker (desktop keybind) -----------------------------------

menu_task_rows() {
    local t
    while IFS= read -r t; do
        printf '%s\t%s\ttask: %s\n' "$ICON_TASK" "$t" "$(task_detail "$t")"
    done < <(list_tasks)
}

menu_repo_rows() {
    local r
    while IFS= read -r r; do
        printf '%s\t%s\t%s\n' "$ICON_REPO" "$(basename "$r")" "$(dirname "${r/#$HOME/\~}")"
    done
}

# Keep asking for repos until "Done"; prints the chosen repo paths.
menu_more_repos() {
    local prompt=$1 sel r chosen=()
    shift
    chosen=("$@")
    while :; do
        sel=$({
            [[ ${#chosen[@]} -gt 0 ]] && printf '%s\tDone\n' "$ICON_DONE"
            list_repos | grep -vxF -f <(printf '%s\n' "${chosen[@]}") | menu_repo_rows
        } | omarchy-menu-select "$prompt" -- --width 700) || break
        [[ "$sel" == Done ]] && break
        r="${sel#*$'\t'}/${sel%%$'\t'*}"
        chosen+=("${r/#\~/$HOME}")
    done
    [[ ${#chosen[@]} -gt 0 ]] && printf '%s\n' "${chosen[@]}"
}

pick_menu() {
    local sel label sub task="" branch="" input r repos=()
    mkdir -p "$TASKS_DIR"
    sel=$({
        menu_task_rows
        [[ -n "$(list_tasks)" ]] && printf '%s\t%s\tworktrees for more repos on its branch\n' "$ICON_ADD" "$ADD_LABEL"
        list_repos | menu_repo_rows
    } | omarchy-menu-select "Task or repo" -- --width 700) || exit 0
    label=${sel%%$'\t'*}
    sub=${sel#*$'\t'}

    if [[ "$sub" == "task: "* ]]; then
        task=$label
    elif [[ "$label" == "$ADD_LABEL" ]]; then
        task=$(menu_task_rows | omarchy-menu-select "Add repos to" -- --width 700) || exit 0
        task=${task%%$'\t'*}
        mapfile -t repos < <(menu_more_repos "Repo for $task")
        [[ ${#repos[@]} -gt 0 ]] || exit 0
        add_repos "$task" "" "${repos[@]}"
    else
        r="$sub/$label"
        input=$(omarchy-menu-input "Task name for $label (optional: name branch)" --width 700) || exit 0
        read -r task branch <<< "$input"
        valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
        mapfile -t repos < <(menu_more_repos "$task: add another repo, or Done" "${r/#\~/$HOME}")
        add_repos "$task" "$branch" "${repos[@]}"
    fi
    open_session "$task"
}

# Keep the tmux window open when something went wrong, so the message is seen.
pause_on_error() {
    local rc=$?
    [[ $rc -ne 0 && -t 0 ]] && read -rp "press enter to close"
    exit $rc
}

case "$(basename "$0"):${1:-}" in
    *:list-repos) list_repos ;;
    *:search-rows) python3 "$(dirname "$SELF")/search-identity.py" rows ;;
    *:search-open)
        [[ $# -eq 3 ]] || die "usage: search-open tasks|sessions identifier"
        name=$(python3 "$(dirname "$SELF")/search-identity.py" resolve "$2" "$3") || exit 1
        if [[ "$2" == tasks ]]; then
            TASK_SEARCH=1 open_session "$name"
        elif [[ "$2" == sessions ]]; then
            setsid uwsm-app -- xdg-terminal-exec -e tmux attach-session -t "$name" >/dev/null 2>&1 &
        else die "unknown selection provider"; fi
        ;;
    task-rm:*) remove_task "$@" ;;
    *:rm) shift; remove_task "$@" ;;
    *:hook) run_hook "${2:?task}" "${3:?repo}" ;;
    *:add)
        shift
        [[ $# -gt 0 ]] || die "usage: add <task> [repo..]"
        task=$1
        shift
        if [[ $# -eq 0 ]]; then mapfile -t picked < <(fzf_repos "add to $task"); set -- "${picked[@]}"; fi
        add_repos "$task" "" "$@" && dispatch_hooks "$task"
        herdr_running "$(session_name "$task")" && herdr_layout "$task" && herdr_announce "$task"
        ;;
    *:sessions) [[ "${2:-}" == popup ]] && TASK_POPUP=1; pick_session ;;
    # Used by the pontual.tasks shell plugin (Super+S).
    *:rows) session_rows ;;
    *:open)
        TASK_POPUP=1
        if [[ -d "$TASKS_DIR/${2:?name}" ]]; then open_session "$2"; else goto_session "$2"; fi
        ;;
    *:kill) tmux kill-session -t "=${2:?name}" && echo "killed session $2" ;;
    *:popup) TASK_POPUP=1; pick_menu ;;
    *:) trap pause_on_error EXIT; pick ;;
    *) die "unknown command: $1" ;;
esac
