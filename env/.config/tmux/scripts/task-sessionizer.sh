#!/usr/bin/env bash
# Task-scoped tmux sessionizer. A task is ~/tasks/<task>/ with worker repo
# worktrees plus optional read-only context repo records; its tmux session and
# herdr session are scoped to it.
#
#   task-sessionizer.sh                      fzf picker: tasks and repos
#   task-sessionizer.sh popup                same, in the Omarchy menu (keybind)
#   task-sessionizer.sh sessions             session manager in the terminal
#                                            (Super+S opens the task picker)
#   task-sessionizer.sh create <task> [--worker repo|--context repo]...
#   task-sessionizer.sh add <task> [--worker repo|--context repo]...
#   task-sessionizer.sh promote <task> <repo> context -> worker
#   task-sessionizer.sh demote <task> <repo> [--dry-run] [--force]
#                                            worker -> context; worktree removed, branch kept
#   task-sessionizer.sh remove <task> <repo> [--dry-run] [--force]
#                                            drop a repo from the task; branch kept
#   task-sessionizer.sh close <task> [--force] close a task; branches remain
#   task-sessionizer.sh rm <task> [--force]  remove worktrees, dir and session
#   task-sessionizer.sh stop <task> [--dry-run] [--force]
#                                            end its nvim, language servers and
#                                            herdr session; worktrees and branches stay
#   task-sessionizer.sh list                 tasks with state and RAM
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
ICON_CONTEXT=$'󰈙'
CREATE_LABEL="Create new task"
ADD_LABEL="Add repo to task"
CLOSE_LABEL="Close task"
REPOS_LABEL="Task repos"

# Worktrees created in this run whose post-create hook still has to run.
PENDING=()
# Repos added in this run, announced to a running orchestrator.
NEW_REPOS=()
NEW_CONTEXTS=()

die() {
    echo "error: $*" >&2
    [[ -n "${TASK_POPUP:-}" ]] && notify-send "Task sessionizer" "$*"
    exit 1
}

# Canonical repos are found at any depth under Projects and Work. Only .git
# directories count; task worktrees (.git files) are intentionally skipped.
list_repos() {
    fd -H -I -t d '^\.git$' "${REPO_ROOTS[@]}" 2>/dev/null |
        sed 's#/\.git/\{0,1\}$##' | sort -u
}

list_tasks() {
    [[ -d "$TASKS_DIR" ]] || return 0
    find "$TASKS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

task_worktrees() {
    local d name order_file="$TASKS_DIR/$1/.task-worker-order"
    local -a ordered=()
    local -A seen=()
    if [[ -f "$order_file" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" && -z "${seen[$name]:-}" ]] || continue
            d="$TASKS_DIR/$1/$name"
            [[ -e "$d/.git" ]] || continue
            seen[$name]=1
            ordered+=("$d")
        done < "$order_file"
    fi
    for d in "${ordered[@]}"; do
        echo "$d"
    done
    for d in "$TASKS_DIR/$1"/*/; do
        [[ -e "${d}.git" ]] || continue
        name=${d%/}
        name=${name##*/}
        [[ -n "${seen[$name]:-}" ]] && continue
        echo "${d%/}"
    done
}

# Persist worker insertion order. When upgrading an existing task that lacks
# metadata, retain the current tmux nvim-window order before appending workers.
ensure_worker_order() {
    local task=$1 file="$TASKS_DIR/$1/.task-worker-order" tmp wt name
    local -a names=()
    local -A seen=()
    [[ -f "$file" ]] && return 0
    # Existing task AGENTS.md repo ordering is the durable legacy record. Use
    # it before inferring order from a live session or the directory glob.
    while IFS= read -r name; do
        [[ -e "$TASKS_DIR/$task/$name/.git" ]] || continue
        [[ -n "${seen[$name]:-}" ]] && continue
        names+=("$name")
        seen[$name]=1
    done < <(task_agents_worker_order "$task")
    if tmux has-session -t "=$(session_name "$task")" 2>/dev/null; then
        while IFS= read -r name; do
            [[ "$name" == nvim-* ]] || continue
            name=${name#nvim-}
            [[ -e "$TASKS_DIR/$task/$name/.git" ]] || continue
            [[ -n "${seen[$name]:-}" ]] && continue
            names+=("$name")
            seen[$name]=1
        done < <(tmux list-windows -t "=$(session_name "$task")" -F '#W')
    fi
    while IFS= read -r wt; do
        name=$(basename "$wt")
        [[ -n "${seen[$name]:-}" ]] && continue
        names+=("$name")
        seen[$name]=1
    done < <(task_worktrees "$task")
    tmp=$(mktemp "$TASKS_DIR/$task/.task-worker-order.XXXXXX") || return 1
    if ((${#names[@]})); then printf '%s\n' "${names[@]}" > "$tmp"; fi
    chmod 600 "$tmp" && mv -f "$tmp" "$file"
}

task_agents_worker_order() {
    python3 - "$TASKS_DIR/$1/AGENTS.md" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(0)
text = path.read_text(errors="replace")
lines = text.splitlines()
sections = []
in_repos = False
in_workers = False
for line in lines:
    if re.match(r"^##\s+Repos\s*$", line, re.I):
        in_repos, in_workers = True, False
        continue
    if re.match(r"^###\s+Worker repos\s*$", line, re.I):
        in_workers = True
        in_repos = False
        continue
    if re.match(r"^##\s+", line):
        in_repos = in_workers = False
    elif re.match(r"^###\s+", line):
        in_workers = False
    if in_repos or in_workers:
        sections.append((in_repos or in_workers, line))

seen = set()
for active, line in sections:
    if not active:
        continue
    match = re.match(r"^\s*-\s+\*\*(.+?)\*\*", line)
    if not match:
        match = re.match(r"^\s*-\s+([^\s:|—]+)", line)
    if not match:
        match = re.match(r"^\s*\|\s*([^|]+?)\s*\|", line)
    if match:
        name = match.group(1).strip().strip("`")
        if name and name not in seen and name.lower() not in {"repo", "name", "none yet"}:
            print(name)
            seen.add(name)
PY
}

record_worker_order() {
    local task=$1 added=$2 file="$TASKS_DIR/$1/.task-worker-order" tmp wt name
    local -a names=()
    local -A seen=()
    if [[ ! -f "$file" ]]; then
        if tmux has-session -t "=$(session_name "$task")" 2>/dev/null; then
            while IFS= read -r name; do
                [[ "$name" == nvim-* ]] || continue
                name=${name#nvim-}
                [[ -e "$TASKS_DIR/$task/$name/.git" && "$name" != "$added" ]] || continue
                [[ -n "${seen[$name]:-}" ]] && continue
                names+=("$name")
                seen[$name]=1
            done < <(tmux list-windows -t "=$(session_name "$task")" -F '#W')
        fi
        while IFS= read -r wt; do
            name=$(basename "$wt")
            [[ "$name" == "$added" || -n "${seen[$name]:-}" ]] && continue
            names+=("$name")
            seen[$name]=1
        done < <(task_worktrees "$task")
    else
        while IFS= read -r name; do
            [[ -n "$name" && "$name" != "$added" && -z "${seen[$name]:-}" ]] || continue
            [[ -e "$TASKS_DIR/$task/$name/.git" ]] || continue
            names+=("$name")
            seen[$name]=1
        done < "$file"
    fi
    names+=("$added")
    tmp=$(mktemp "$TASKS_DIR/$task/.task-worker-order.XXXXXX") || return 1
    printf '%s\n' "${names[@]}" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && mv -f "$tmp" "$file"
}

task_context_file() { printf '%s/.task-context.tsv\n' "$TASKS_DIR/$1"; }

task_contexts() {
    local file
    file=$(task_context_file "$1")
    [[ -f "$file" ]] || return 0
    cat "$file"
}

repo_is_context() {
    local task=$1 repo=$2 name path
    while IFS=$'\t' read -r name path; do
        [[ "$path" == "$repo" ]] && return 0
    done < <(task_contexts "$task")
    return 1
}

# "api, web on feat-x", prefixed with "running" when its session is up.
task_detail() {
    local wt names="" branch="" context
    while IFS= read -r wt; do
        names+="${names:+, }$(basename "$wt")"
        [[ -n "$branch" ]] || branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    done < <(task_worktrees "$1")
    while IFS=$'\t' read -r context _; do
        [[ -n "$context" ]] && names+="${names:+, }${context} (context)"
    done < <(task_contexts "$1")
    [[ -n "$names" ]] || names="no repos"
    [[ -z "$branch" ]] || names="$names on $branch"
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
    local task=$1 branch=$2 repo=${3%/} name wt existing origin allow_context=${4:-no}
    repo=$(canonical_repo "$repo") || { echo "skip $repo: not a canonical git checkout under ~/Projects or ~/Work"; return 1; }
    name=$(basename "$repo")
    wt="$TASKS_DIR/$task/$name"
    if [[ "$allow_context" != yes ]] && repo_is_context "$task" "$repo"; then
        die "$name is context-only in $task; use promote $task $name to create a worker"
    fi
    if [[ -e "$wt" ]]; then
        origin=$(origin_repo "$wt")
        [[ "$origin" == "$repo" ]] && { echo "$name: already in $task"; return 0; }
        die "repo name collision in $task: $name"
    fi
    mkdir -p "$TASKS_DIR/$task"
    ensure_worker_order "$task" || die "could not initialize worker order for $task"
    echo "$name: worktree on $branch"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" ||
        [[ -n "$(git -C "$repo" for-each-ref "refs/remotes/*/$branch")" ]]; then
        git -C "$repo" worktree add "$wt" "$branch" || return 1
    else
        git -C "$repo" worktree add -b "$branch" "$wt" || return 1
    fi
    record_worker_order "$task" "$name" || die "could not record worker order for $task/$name"
    PENDING+=("$name")
    NEW_REPOS+=("$name")
    # Keep a running task session in sync with its repo worktrees.
    tmux has-session -t "=$(session_name "$task")" 2>/dev/null &&
        ensure_task_layout "$task"
}

write_agents_md() {
    local task=$1 branch=$2 file="$TASKS_DIR/$1/AGENTS.md" wt
    write_claude_files "$task"
    mkdir -p "$TASKS_DIR/$task/research"
    if [[ ! -e "$file" ]]; then
        cat > "$file" <<EOF
# $task

## Goal

## Repos

## Agents
| name | role | model / effort | herdr workspace |
|---|---|---|---|

## Cross-repo contracts
(Shared endpoints, payload shapes, file formats and names that repos depend on, numbered C1, C2, …)

## Plan / status
(Numbered steps, one owner repo each, with checks; [checkpoint] marks where the user gets a report.)

## Notes for agents
- Worker repo subfolders are task worktrees on the branch shown in Repo modes. Each worker writes only inside its assigned worktree.
- Context-only repos are canonical checkouts listed in Repo modes; they are read-only references with no worktree or repo agent.
- Researcher notes belong under the task root's \`research/\`; researcher never edits repository trees.
- Don't \`git checkout\` other branches; use the existing task worktrees.
- Each agent's role comes from its launch prompt (~/.config/tmux/scripts/task-roles/). The orchestrator maintains the task plan and shared contracts.
EOF
    fi
    sync_repo_modes "$task"
}

sync_repo_modes() {
    local task=$1
    python3 - "$TASKS_DIR/$task" <<'PY'
from pathlib import Path
import os
import re
import subprocess
import tempfile
import sys

root = Path(sys.argv[1]).resolve()
agents = root / "AGENTS.md"
contexts_file = root / ".task-context.tsv"
workers = []
ordered_names = []
order_file = root / ".task-worker-order"
if order_file.is_file():
    ordered_names = [name for name in order_file.read_text().splitlines() if name]
worktrees = {p.name: p for p in root.iterdir() if p.is_dir() and (p / ".git").exists()}
worker_names = list(dict.fromkeys(ordered_names + sorted(worktrees, key=str.casefold)))
for name in worker_names:
    worktree = worktrees.get(name)
    if worktree is None:
        continue
    try:
        common = subprocess.check_output(
            ["git", "-C", str(worktree), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
        branch = subprocess.check_output(
            ["git", "-C", str(worktree), "branch", "--show-current"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        continue
    canonical = str(Path(common).resolve().parent)
    workers.append((worktree.name, str(worktree.resolve()), canonical, branch))

contexts = []
if contexts_file.is_file():
    for line in contexts_file.read_text().splitlines():
        if "\t" not in line:
            continue
        name, path = line.split("\t", 1)
        if name and path:
            contexts.append((name, path))

def md(s):
    return s.replace("`", "\\`").replace("|", "\\|")

lines = [
    "## Repo modes",
    "",
    "<!-- task-sessionizer:repo-modes:start -->",
    "### Worker repos",
]
if workers:
    lines.extend(
        f"- **{md(name)}** — worktree `{md(worktree)}`; canonical checkout `{md(canonical)}`; branch `{md(branch or '?')}`."
        for name, worktree, canonical, branch in workers
    )
else:
    lines.append("- None yet.")
lines.extend(["", "### Context only (read-only)"])
if contexts:
    lines.extend(
        f"- **{md(name)}** — canonical checkout `{md(path)}`; read-only reference, no task worktree or repo agent."
        for name, path in sorted(contexts, key=lambda row: row[0].casefold())
    )
else:
    lines.append("- None.")
lines.extend(["", "<!-- task-sessionizer:repo-modes:end -->"])
block = "\n".join(lines)
text = agents.read_text() if agents.exists() else f"# {root.name}\n"
start = "<!-- task-sessionizer:repo-modes:start -->"
end = "<!-- task-sessionizer:repo-modes:end -->"
if start in text or end in text:
    if start not in text or end not in text:
        raise SystemExit("incomplete task-sessionizer Repo modes markers in AGENTS.md")
    text = re.sub(re.escape(start) + r".*?" + re.escape(end), block[len("## Repo modes\n\n"):], text, count=1, flags=re.S)
else:
    match = re.search(r"(?m)^## Agents\s*$", text)
    insertion = block + "\n\n"
    if match:
        text = text[:match.start()] + insertion + text[match.start():]
    else:
        text = text.rstrip() + "\n\n" + block + "\n"

mode = agents.stat().st_mode & 0o777 if agents.exists() else 0o644
fd, temporary = tempfile.mkstemp(prefix=".AGENTS.md.", dir=root)
try:
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(temporary, mode)
    os.replace(temporary, agents)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

canonical_repo() {
    local input=${1/#\~/$HOME} path root allowed=no
    path=$(realpath -e "$input") || return 1
    [[ -d "$path/.git" ]] || return 1
    for root in "${REPO_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        root=$(realpath -e "$root")
        [[ "$path" == "$root"/* ]] && allowed=yes
    done
    [[ "$allowed" == yes ]] || return 1
    printf '%s\n' "$path"
}

add_context() {
    local task=$1 input=$2 repo name file existing_name existing_path tmp worker origin
    valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
    repo=$(canonical_repo "$input") || die "context repo must be a canonical git checkout under ~/Projects or ~/Work: $input"
    name=$(basename "$repo")
    mkdir -p "$TASKS_DIR/$task"
    while IFS= read -r worker; do
        [[ "$(basename "$worker")" == "$name" ]] || continue
        origin=$(origin_repo "$worker")
        [[ "$origin" == "$repo" ]] && { echo "$name: already a worker in $task"; return 0; }
        die "repo name collision in $task: $name"
    done < <(task_worktrees "$task")
    file=$(task_context_file "$task")
    while IFS=$'\t' read -r existing_name existing_path; do
        [[ -n "$existing_name" ]] || continue
        [[ "$existing_path" == "$repo" ]] && { echo "$name: already context in $task"; return 0; }
        [[ "$existing_name" != "$name" ]] || die "context repo name collision in $task: $name"
    done < <(task_contexts "$task")
    tmp=$(mktemp "$(dirname "$file")/.task-context.XXXXXX")
    task_contexts "$task" > "$tmp"
    printf '%s\t%s\n' "$name" "$repo" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
    NEW_CONTEXTS+=("$name")
    echo "$name: recorded as read-only context"
}

remove_context() {
    local task=$1 selector=$2 file tmp name path found=0
    file=$(task_context_file "$task")
    [[ -f "$file" ]] || die "no context repos recorded for $task"
    tmp=$(mktemp "$(dirname "$file")/.task-context.XXXXXX")
    while IFS=$'\t' read -r name path; do
        if [[ "$selector" == "$name" || "$selector" == "$path" || "$selector" == "$(basename "$path")" ]]; then
            found=1
            continue
        fi
        [[ -n "$name" ]] && printf '%s\t%s\n' "$name" "$path" >> "$tmp"
    done < "$file"
    [[ $found == 1 ]] || { unlink "$tmp"; die "no context repo matches $selector in $task"; }
    if [[ -s "$tmp" ]]; then chmod 600 "$tmp"; mv -f "$tmp" "$file"; else unlink "$tmp"; unlink "$file"; fi
}

# Summarize all data that makes task closure destructive. A normal close is
# blocked for dirty/conflicted worktrees, commits not merged into the repo's
# default branch, and non-generated task-root files. Branch refs are preserved.
task_close_issues() {
    local task=$1 dir="$TASKS_DIR/$1" wt name status state dirty_count conflict branch base ref ahead
    local entry sub extra settings
    local -A workers=()
    while IFS= read -r wt; do workers["$(basename "$wt")"]=1; done < <(task_worktrees "$task")

    while IFS= read -r wt; do
        name=$(basename "$wt")
        status=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null) || {
            printf '%s: unable to read git status; close blocked\n' "$name"
            continue
        }
        if [[ -n "$status" ]]; then
            dirty_count=$(awk 'END { print NR+0 }' <<< "$status")
            conflict=no
            while IFS= read -r state; do
                state=${state:0:2}
                [[ "$state" == *U* || "$state" == AA || "$state" == DD ]] && conflict=yes
            done <<< "$status"
            if [[ "$conflict" == yes ]]; then
                printf '%s: %s unmerged/conflicted path(s)\n' "$name" "$dirty_count"
            else
                printf '%s: %s uncommitted path(s)\n' "$name" "$dirty_count"
            fi
        fi

        branch=$(git -C "$wt" branch --show-current 2>/dev/null)
        base=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
        for ref in "$base" origin/main origin/master main master trunk; do
            [[ -n "$ref" && "$ref" != "$branch" ]] || continue
            git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || continue
            base=$ref
            break
        done
        if [[ -n "$base" && "$base" != "$branch" ]]; then
            ahead=$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)
            if [[ "$ahead" =~ ^[0-9]+$ ]] && ((ahead > 0)); then
                printf '%s: %s unmerged commit(s) versus %s (branch will be kept)\n' "$name" "$ahead" "$base"
            fi
        fi
    done < <(task_worktrees "$task")

    # remove_task cleans these generated entries. Anything else is explicitly
    # named because --force removes the residual task directory as well.
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name=${entry##*/}
        [[ -n "${workers[$name]:-}" ]] && continue
        case "$name" in
            AGENTS.md|REPORT.md|.task-context.tsv|.task-worker-order) ;;
            CLAUDE.md)
                if [[ ! -L "$entry" && "$(cat "$entry" 2>/dev/null)" != "@AGENTS.md" ]]; then
                    printf '%s: custom task-root file %s\n' "$task" "$name"
                fi
                ;;
            research)
                if [[ -d "$entry" ]] && find "$entry" -mindepth 1 -print -quit | grep -q .; then
                    printf '%s: research notes/files (force close removes them)\n' "$task"
                fi
                ;;
            .claude)
                extra=no
                for sub in "$entry"/* "$entry"/.[!.]*; do
                    [[ -e "$sub" || -L "$sub" ]] || continue
                    case "${sub##*/}" in
                        settings.local.json) ;;
                        settings.json)
                            settings=$(cat "$sub" 2>/dev/null)
                            [[ "$settings" == "$CLAUDE_TASK_SETTINGS" || "$settings" == "$CLAUDE_TASK_SETTINGS_OLD" ]] || extra=yes
                            ;;
                        *) extra=yes ;;
                    esac
                done
                [[ "$extra" == yes ]] && printf '%s: custom task-root data in .claude (force close removes it)\n' "$task"
                ;;
            *) printf '%s: additional task-root data at %s (force close removes it)\n' "$task" "$name" ;;
        esac
    done
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

    [[ -n "$(task_worktrees "$task")" ]] || die "no worker worktree could be created for $task"
    write_agents_md "$task" "$branch"
}

add_contexts() {
    local task=$1 repo
    shift
    mkdir -p "$TASKS_DIR/$task"
    for repo in "$@"; do add_context "$task" "$repo"; done
    write_agents_md "$task" "$(task_branch "$task")"
}

task_branch() {
    local wt
    wt=$(task_worktrees "$1" | head -n1)
    [[ -n "$wt" ]] && git -C "$wt" branch --show-current || printf '%s\n' "$1"
}

create_task() {
    local task=$1 repo branch
    shift
    local -a workers=() contexts=()
    valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
    while (($#)); do
        case "$1" in
            --worker) (($# >= 2)) || die "--worker needs a repo path"; workers+=("$2"); shift 2 ;;
            --context) (($# >= 2)) || die "--context needs a repo path"; contexts+=("$2"); shift 2 ;;
            *) die "unknown create option: $1" ;;
        esac
    done
    ((${#workers[@]} + ${#contexts[@]} > 0)) || die "create needs at least one --worker or --context repo"
    [[ ! -e "$TASKS_DIR/$task" ]] || die "task already exists: $task"
    mkdir -p "$TASKS_DIR/$task/research"
    branch=$task
    for repo in "${workers[@]}"; do add_repo "$task" "$branch" "$repo"; done
    for repo in "${contexts[@]}"; do add_context "$task" "$repo"; done
    write_agents_md "$task" "$branch"
}

add_task_repos() {
    local task=$1 repo
    shift
    local -a workers=() contexts=()
    valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
    while (($#)); do
        case "$1" in
            --worker) (($# >= 2)) || die "--worker needs a repo path"; workers+=("$2"); shift 2 ;;
            --context) (($# >= 2)) || die "--context needs a repo path"; contexts+=("$2"); shift 2 ;;
            --*) die "unknown add option: $1" ;;
            *) workers+=("$1"); shift ;;
        esac
    done
    ((${#workers[@]} + ${#contexts[@]} > 0)) || die "add needs at least one repo"
    [[ -d "$TASKS_DIR/$task" ]] || mkdir -p "$TASKS_DIR/$task/research"
    if ((${#workers[@]})); then add_repos "$task" "$(task_branch "$task")" "${workers[@]}"; fi
    if ((${#contexts[@]})); then
        for repo in "${contexts[@]}"; do add_context "$task" "$repo"; done
        write_agents_md "$task" "$(task_branch "$task")"
    fi
    if tmux has-session -t "=$(session_name "$task")" 2>/dev/null; then
        ensure_task_layout "$task"
        herdr_running "$(session_name "$task")" && herdr_layout "$task" && herdr_announce "$task"
    fi
}

promote_context() {
    local task=$1 selector=$2 name path branch
    valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
    [[ -d "$TASKS_DIR/$task" ]] || die "no such task: $task"
    path=$(awk -F '\t' -v selector="$selector" '$1 == selector || $2 == selector { print $2; found=1; exit } END { if (!found) exit 1 }' \
        "$(task_context_file "$task")") || die "no context repo matches $selector in $task"
    name=$(basename "$path")
    branch=$(task_branch "$task")
    add_repo "$task" "$branch" "$path" yes
    remove_context "$task" "$path"
    write_agents_md "$task" "$branch"
    ensure_task_runtime "$task"
    dispatch_hooks "$task"
    herdr_running "$(session_name "$task")" && herdr_layout "$task" && herdr_announce "$task"
    echo "$name promoted to worker in $task"
}

# --- demote and remove -------------------------------------------------------
# demote turns a worker back into a read-only context: its agent stops, its
# herdr workspace and tmux windows close, and its worktree is removed. The
# branch is always kept. remove drops a repo from the task entirely (demoting
# it first when it is a worker) and refuses to empty a task.

# Default branch of a worktree's repo, found the same way task close looks for it.
worktree_base() {
    local wt=$1 branch base ref
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    base=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    for ref in "$base" origin/main origin/master main master trunk; do
        [[ -n "$ref" && "$ref" != "$branch" ]] || continue
        git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || continue
        base=$ref
        break
    done
    printf '%s\n' "$base"
}

# "kind name worktree canonical" for a repo in a task, found by folder name or
# canonical path. Context repos have an empty worktree field.
task_repo_lookup() {
    local task=$1 selector=$2 wt name origin path
    while IFS= read -r wt; do
        name=$(basename "$wt")
        origin=$(origin_repo "$wt")
        if [[ "$selector" == "$name" || "$selector" == "$origin" ]]; then
            printf 'worker\t%s\t%s\t%s\n' "$name" "$wt" "$origin"
            return 0
        fi
    done < <(task_worktrees "$task")
    while IFS=$'\t' read -r name path; do
        if [[ -n "$name" && ( "$selector" == "$name" || "$selector" == "$path" ) ]]; then
            printf 'context\t%s\t\t%s\n' "$name" "$path"
            return 0
        fi
    done < <(task_contexts "$task")
    return 1
}

task_repo_total() {
    local n
    n=$(task_worktrees "$1" | awk 'NF' | wc -l)
    n=$((n + $(task_contexts "$1" | awk 'NF' | wc -l)))
    echo "$n"
}

# Drops a repo's folder name from .task-worker-order (the worktree is gone).
drop_worker_order() {
    local task=$1 name=$2 file="$TASKS_DIR/$1/.task-worker-order" tmp
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp "$TASKS_DIR/$task/.task-worker-order.XXXXXX") || return 1
    grep -Fxv -- "$name" "$file" > "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$file"
}

# Agent name, pane and status for a running agent of a task's herdr session.
task_agent_line() {
    local s=$1 name=$2 info
    command -v herdr >/dev/null && command -v jq >/dev/null || return 1
    herdr_running "$s" || return 1
    info=$(herdr --session "$s" agent get "$name" 2>/dev/null) && [[ -n "$info" ]] || return 1
    jq -r '.result.agent | "\(.pane_id) \(.agent_status)"' <<< "$info"
}

task_workspace_id() {
    local s=$1 label=$2
    herdr_running "$s" || return 1
    herdr --session "$s" workspace list 2>/dev/null |
        jq -r --arg l "$label" '.result.workspaces[] | select(.label == $l) | .workspace_id' | head -n1
}

task_window_exists() {
    tmux list-windows -t "=$1" -F '#W' 2>/dev/null | grep -Fxq -- "$2"
}

# nvim in a task window quits with :qa, so unsaved buffers keep it open.
quit_nvim_window() {
    local s=$1 name=$2 i
    [[ "$(tmux display-message -p -t "=$s:nvim-$name" '#{pane_current_command}' 2>/dev/null)" == nvim ]] || return 0
    tmux send-keys -t "=$s:nvim-$name" Escape ':qa' Enter
    for i in $(seq 1 20); do
        [[ "$(tmux display-message -p -t "=$s:nvim-$name" '#{pane_current_command}' 2>/dev/null)" == nvim ]] || return 0
        sleep 0.25
    done
    return 1
}

# demote_repo <task> <repo> <dry-run yes|no> <force yes|no>
demote_repo() {
    local task=$1 selector=$2 dry=$3 force=$4 kind name wt origin s branch base ahead status
    local agent_pane agent_status ws wtforce=() stopforce=()
    IFS=$'\t' read -r kind name wt origin < <(task_repo_lookup "$task" "$selector") ||
        die "no repo $selector in $task"
    [[ "$kind" == worker ]] || die "$name is already context in $task"
    s=$(session_name "$task")
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    status=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null) ||
        die "$name: unable to read git status"
    if [[ -n "$status" && "$force" != yes ]]; then
        if [[ "$dry" == yes ]]; then
            printf 'refused:   %s has uncommitted or untracked changes; commit, stash or use --force\n' "$name"
            return 1
        fi
        die "$name has uncommitted or untracked changes; commit or stash them, or use --force"
    fi
    base=$(worktree_base "$wt")
    if [[ -n "$base" && "$base" != "$branch" ]]; then
        ahead=$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)
        if [[ "$ahead" =~ ^[0-9]+$ ]] && ((ahead > 0)); then
            printf 'warning:   %s has %s commit(s) not merged into %s; the branch is kept either way\n' "$name" "$ahead" "$base"
        fi
    fi
    [[ "$force" == yes ]] && wtforce=(--force) && stopforce=(--force)

    # Agent: stopped first, since a working agent refuses without --force.
    if agent=$(task_agent_line "$s" "$name"); then
        read -r agent_pane agent_status <<< "$agent"
        if [[ "$agent_status" == working && "$force" != yes ]]; then
            if [[ "$dry" == yes ]]; then
                printf 'refused:   agent %s is working; wait for it or use --force\n' "$name"
                return 1
            fi
            die "agent $name is working; wait for it or use demote $task $name --force"
        fi
        if [[ "$dry" == yes ]]; then
            printf 'agent:     stop %s (pane %s, %s) with /exit\n' "$name" "$agent_pane" "$agent_status"
        else
            TASK_SESSION=$s "$(dirname "$SELF")/task-agent.sh" stop "$name" "${stopforce[@]}" ||
                die "could not stop agent $name; the worktree was not touched"
        fi
    elif [[ "$dry" == yes ]]; then
        printf 'agent:     none running\n'
    fi

    # Window and workspace: nvim must quit cleanly; the server window and the herdr workspace close.
    if task_window_exists "$s" "nvim-$name"; then
        if [[ "$dry" == yes ]]; then
            printf 'window:    quit nvim-%s (:qa; refused if it has unsaved buffers)\n' "$name"
        elif ! quit_nvim_window "$s" "$name"; then
            die "nvim-$name still has unsaved buffers; save or quit it, then retry"
        fi
    fi
    if task_window_exists "$s" "srv-$name"; then
        if [[ "$dry" == yes ]]; then
            printf 'window:    close srv-%s (its processes stop)\n' "$name"
        else
            tmux kill-window -t "=$s:srv-$name" 2>/dev/null || true
        fi
    fi
    ws=$(task_workspace_id "$s" "$name" || true)
    if [[ -n "$ws" ]]; then
        if [[ "$dry" == yes ]]; then
            printf 'workspace: close herdr workspace %s (%s) in session %s\n' "$name" "$ws" "$s"
        else
            herdr --session "$s" workspace close "$ws" >/dev/null 2>&1 || true
        fi
    fi

    # Worktree removal keeps the branch; the record moves the repo to context.
    if [[ "$dry" == yes ]]; then
        printf 'worktree:  remove %s (git worktree remove%s); branch %s kept\n' "$wt" "${wtforce:+ --force}" "${branch:-?}"
        printf 'record:    drop %s from .task-worker-order; add %s as read-only context in .task-context.tsv\n' "$name" "$origin"
        printf 'agents-md: regenerate the Repo modes block\n'
        return 0
    fi
    git -C "$origin" worktree remove "${wtforce[@]}" "$wt" || die "could not remove worktree $wt"
    git -C "$origin" worktree prune
    drop_worker_order "$task" "$name"
    add_context "$task" "$origin" >/dev/null
    write_agents_md "$task" "$(task_branch "$task")"
    herdr_running "$s" && herdr_announce "$task"
    echo "$name demoted to context in $task; branch ${branch:-?} kept"
}

# repo_remove <task> <repo> <dry-run yes|no> <force yes|no>
repo_remove() {
    local task=$1 selector=$2 dry=$3 force=$4 kind name wt origin
    IFS=$'\t' read -r kind name wt origin < <(task_repo_lookup "$task" "$selector") ||
        die "no repo $selector in $task"
    if (( $(task_repo_total "$task") <= 1 )); then
        if [[ "$dry" == yes ]]; then
            printf 'refused:   %s is the last repo in %s; use close or rm to end the task\n' "$name" "$task"
            return 1
        fi
        die "$name is the last repo in $task; use close or rm to end the task"
    fi
    if [[ "$kind" == worker ]]; then
        demote_repo "$task" "$name" "$dry" "$force" || return 1
    fi
    if [[ "$dry" == yes ]]; then
        printf 'record:    remove %s from .task-context.tsv\n' "$name"
        printf 'agents-md: regenerate the Repo modes block\n'
        printf 'branch:    kept\n'
        return 0
    fi
    remove_context "$task" "$name"
    write_agents_md "$task" "$(task_branch "$task")"
    herdr_running "$(session_name "$task")" && herdr_announce "$task"
    echo "$name removed from $task; its branch is kept"
}

# repo_command <demote|remove> <task> <repo> [--dry-run] [--force]
repo_command() {
    local verb=$1 task=${2:-} selector=${3:-} dry=no force=no arg
    [[ -n "$task" && -n "$selector" ]] || die "usage: $verb <task> <repo> [--dry-run] [--force]"
    valid_name "$task" || die "invalid task name: $task"
    [[ -d "$TASKS_DIR/$task" ]] || die "no such task: $task"
    for arg in "${@:4}"; do
        case "$arg" in
            --dry-run) dry=yes ;;
            --force) force=yes ;;
            *) die "usage: $verb <task> <repo> [--dry-run] [--force]" ;;
        esac
    done
    case "$verb" in
        demote) demote_repo "$task" "$selector" "$dry" "$force" ;;
        remove) repo_remove "$task" "$selector" "$dry" "$force" ;;
    esac
}

# Repo rows for the menus: "icon<TAB>name<TAB>name  worker|context".
task_repo_rows() {
    local task=$1 wt name path
    while IFS= read -r wt; do
        name=$(basename "$wt")
        printf '%s\t%s\t%s  worker\n' "$ICON_REPO" "$name" "$name"
    done < <(task_worktrees "$task")
    while IFS=$'\t' read -r name path; do
        [[ -n "$name" ]] && printf '%s\t%s\t%s  context\n' "$ICON_CONTEXT" "$name" "$name"
    done < <(task_contexts "$task")
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
    ensure_worker_order "$task"
    mapfile -t wts < <(task_worktrees "$task")
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

ensure_task_runtime() {
    local task=$1 s created=0
    s=$(session_name "$task")
    command -v tmux >/dev/null || die "tmux is required to prepare task session resources"
    if ! tmux has-session -t "=$s" 2>/dev/null; then
        tmux new-session -ds "$s" -n agent -c "$(realpath "$TASKS_DIR/$task")"
        tmux set-option -t "$s" @pontual_task_root "$(realpath "$TASKS_DIR/$task")"
        created=1
    fi
    ensure_task_layout "$task"
    if command -v herdr >/dev/null; then
        herdr_layout "$task"
        if [[ $created == 1 ]]; then tmux send-keys -t "=$s:agent" "herdr --session $s" Enter; fi
    fi
    TASK_RUNTIME_CREATED=$created
}

open_session() {
    local task=$1 s
    s=$(session_name "$task")
    ensure_task_runtime "$task"
    herdr_running "$s" && herdr_layout "$task" && herdr_announce "$task"
    dispatch_hooks "$task"
    goto_session "$s"
}

# --- herdr (agents) ----------------------------------------------------------

# Tell a running orchestrator about worker/context changes so it updates its
# plan and starts agents only for worker repos.
herdr_announce() {
    local task=$1 s ws pane msg
    [[ ${#NEW_REPOS[@]} -gt 0 || ${#NEW_CONTEXTS[@]} -gt 0 ]] || return 0
    msg="Task repos changed. Worker repos added: ${NEW_REPOS[*]:-none}. Read-only context repos added: ${NEW_CONTEXTS[*]:-none}. Repo modes are recorded in AGENTS.md; refresh workspace/pane state, start agents only for workers, and update the plan."
    NEW_REPOS=()
    NEW_CONTEXTS=()
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

# One persistent herdr session per task, with an orchestrator workspace at the
# task root, one per worker repo, and one researcher workspace under research/.
# Context repos have no workspace. Existing legacy workspaces remain untouched.
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
    mkdir -p "$TASKS_DIR/$task/research"
    want+=("$TASKS_DIR/$task")
    want+=("${wts[@]}")
    want+=("$TASKS_DIR/$task/research")
    for wt in "${want[@]}"; do
        if [[ "$wt" == "$TASKS_DIR/$task/research" ]]; then label=research; else label=$(basename "$wt"); fi
        grep -qxF "\"label\":\"$label\"" <<< "$labels" && continue
        # The task-root workspace is the orchestrator, which starts
        # the repo agents itself, so repo panes must stay at a shell prompt.
        role=()
        picker=
        if [[ "$wt" == "$TASKS_DIR/$task" ]]; then
            role=(--env TASK_ROLE=orchestrator)
            picker=1
        elif [[ "$label" == research ]]; then
            role=(--env TASK_ROLE=researcher)
        fi
        pane=$(herdr --session "$s" workspace create --cwd "$wt" --label "$label" "${role[@]}" --no-focus 2>/dev/null |
            grep -o '"pane_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
        # Opens on the agent picker (claude / codex / opencode).
        [[ -n "$picker" && -n "$pane" && -x "$AGENT_PICKER" ]] &&
            herdr --session "$s" pane run "$pane" "$AGENT_PICKER" >/dev/null 2>&1
    done
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
    local task=${1:-} force=${2:-} dir wt origin s issues wts=() origins=() settings
    [[ -n "$task" ]] || die "usage: rm <task> [--force]"
    dir="$TASKS_DIR/$task"
    [[ -d "$dir" ]] || die "no such task: $task"
    mapfile -t wts < <(task_worktrees "$task")

    issues=$(task_close_issues "$task")
    if [[ -n "$issues" && "$force" != --force ]]; then
        printf 'Close blocked for %s; review these items first:\n%s\n' "$task" "$issues" >&2
        die "use close $task --force only after reviewing; task branches are kept"
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
    rm -f "$(task_context_file "$task")"
    rm -f "$dir/.task-worker-order"
    rmdir "$dir/research" 2>/dev/null || true
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

close_task() {
    local task=${1:-} force=${2:-}
    [[ -n "$task" ]] || die "usage: close <task> [--force]"
    [[ $# -le 2 && ( -z "$force" || "$force" == --force ) ]] || die "usage: close <task> [--force]"
    valid_name "$task" || die "invalid task name: $task"
    remove_task "$task" "$force"
}

# --- stop and list -----------------------------------------------------------
# A task's live processes are the shells in its tmux session (each owns an
# nvim instance and the language servers it started) and its herdr server
# (which owns the agents). Worktrees, branches, files and the tmux session with
# its shells are never touched.

# One "pid rss args" line per root and each of its descendants, from one ps run.
process_subtree() {
    ps -eo pid=,ppid=,rss=,args= | awk -v roots="$*" '
        {
            pid = $1; rss[pid] = $3; kids[$2] = kids[$2] " " pid
            $1 = ""; $2 = ""; $3 = ""; sub(/^ +/, "")
            args[pid] = $0
        }
        END {
            n = split(roots, r, " ")
            for (i = 1; i <= n; i++) queue[++last] = r[i]
            for (head = 1; head <= last; head++) {
                p = queue[head]
                if (!(p in args) || (p in seen)) continue
                seen[p] = 1
                print p, rss[p], args[p]
                m = split(kids[p], c, " ")
                for (j = 1; j <= m; j++) queue[++last] = c[j]
            }
        }'
}

herdr_server_pid() {
    ps -eo pid=,args= | awk -v want="herdr --session $1 server" '
        { pid = $1; $1 = ""; sub(/^ +/, "") }
        $0 == want || index($0, want " ") == 1 { print pid }'
}

# Roots of a task's processes: its tmux pane shells and its herdr server.
task_roots() {
    tmux list-panes -s -t "=$1" -F '#{pane_pid}' 2>/dev/null
    herdr_server_pid "$1"
}

task_rss_kb() {
    local -a roots=()
    mapfile -t roots < <(task_roots "$(session_name "$1")")
    process_subtree "${roots[@]}" | awk '{ total += $2 } END { print total + 0 }'
}

format_mib() { awk -v kb="$1" 'BEGIN { printf "%.0f MiB", kb / 1024 }'; }

# Per task: state and the RAM of its processes (RSS summed, so shared pages
# can count more than once).
list_task_resources() {
    local t s state
    printf '%-28s %-8s %s\n' TASK STATE RAM
    while IFS= read -r t; do
        s=$(session_name "$t")
        if herdr_running "$s"; then
            state=running
        elif tmux has-session -t "=$s" 2>/dev/null; then
            state=tmux
        else
            state=stopped
        fi
        printf '%-28s %-8s %s\n' "$t" "$state" "$(format_mib "$(task_rss_kb "$t")")"
    done < <(list_tasks)
}

# Ends a task's live processes; nothing on disk changes. nvim is asked to quit
# with :qa, so an instance with unsaved buffers stays open, and its language
# servers stop with it. The herdr session is stopped, which ends its agents;
# its workspaces stay and come back with the next start. An agent that is
# working blocks the stop unless --force is given.
stop_task() {
    local task=$1 dry=$2 force=$3 s pane win pane_pid cmd nvim_pid herdr_pid n pid
    local -a nvim_panes=() busy=() agents=() workspaces=() herdr_procs=() stopped=() kept=() lsp=() leftover=()
    local -A nvim_of=() nvim_win=() lsp_of=()

    [[ -d "$TASKS_DIR/$task" ]] || die "no such task: $task"
    s=$(session_name "$task")

    # nvim instances: the top-level nvim under each pane shell. Its child
    # (the --embed process) and everything below it are its language servers.
    if tmux has-session -t "=$s" 2>/dev/null; then
        while read -r pane win pane_pid cmd; do
            [[ "$cmd" == nvim ]] || continue
            nvim_pid=$(process_subtree "$pane_pid" | awk '$3 == "nvim" && $4 != "--embed" { print $1; exit }')
            [[ -n "$nvim_pid" ]] || continue
            nvim_panes+=("$pane")
            nvim_of[$pane]=$nvim_pid
            nvim_win[$pane]=$win
            lsp_of[$pane]=$(process_subtree "$nvim_pid" | awk -v self="$nvim_pid" '$1 != self && $3 != "nvim" { print $1 }' | tr '\n' ' ')
        done < <(tmux list-panes -s -t "=$s" -F '#{pane_id} #{window_name} #{pane_pid} #{pane_current_command}')
    fi

    herdr_pid=
    if herdr_running "$s"; then
        command -v jq >/dev/null || die "jq is required to stop herdr session $s"
        herdr_pid=$(herdr_server_pid "$s")
        mapfile -t agents < <(herdr --session "$s" pane list 2>/dev/null |
            jq -r '.result.panes[] | select(.agent) | "\(.pane_id) \(.agent) \(.agent_status)"')
        mapfile -t busy < <(printf '%s\n' "${agents[@]}" | awk '$3 == "working"')
        mapfile -t workspaces < <(herdr --session "$s" workspace list 2>/dev/null |
            jq -r '.result.workspaces[].label')
        mapfile -t herdr_procs < <(process_subtree "$herdr_pid" | awk -v self="$herdr_pid" '
            $1 != self { pid = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); print pid, $0 }')
    fi

    if [[ ${#busy[@]} -gt 0 && "$force" != yes ]]; then
        if [[ "$dry" == yes ]]; then
            printf 'would refuse: working agents (use --force): %s\n' "${busy[*]}"
        else
            die "agents are working; wait for them or use stop $task --force: ${busy[*]}"
        fi
    fi

    if [[ "$dry" == yes ]]; then
        printf 'dry run for task %s (tmux and herdr session %s); nothing is changed\n' "$task" "$s"
        for pane in "${nvim_panes[@]}"; do
            printf 'nvim:  pane %s window %s pid %s (:qa; kept if it has unsaved buffers); language servers: %s\n' \
                "$pane" "${nvim_win[$pane]}" "${nvim_of[$pane]}" "${lsp_of[$pane]:-none}"
        done
        [[ ${#nvim_panes[@]} -gt 0 ]] || printf 'nvim:  none running\n'
        if [[ -n "$herdr_pid" ]]; then
            printf 'herdr: stop session %s (server pid %s), workspaces: %s\n' "$s" "$herdr_pid" "${workspaces[*]:-none}"
            for n in "${agents[@]}"; do printf 'agent: pane %s\n' "$n"; done
            for n in "${herdr_procs[@]}"; do printf 'proc:  pid %.110s\n' "$n"; done
        else
            printf 'herdr: not running\n'
        fi
        printf 'kept:  worktrees, branches, task files, tmux session %s and its shells\n' "$s"
        return 0
    fi

    # nvim: ask each instance to quit, then give its language servers a moment
    # to exit with it; any left over are sent SIGTERM.
    for pane in "${nvim_panes[@]}"; do
        tmux send-keys -t "$pane" Escape ':qa' Enter
    done
    for pane in "${nvim_panes[@]}"; do
        pid=${nvim_of[$pane]}
        for n in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
        if kill -0 "$pid" 2>/dev/null; then
            kept+=("$pane")
            continue
        fi
        stopped+=("$pane")
        read -ra lsp <<< "${lsp_of[$pane]}"
        for n in "${lsp[@]}"; do
            for _ in $(seq 1 8); do kill -0 "$n" 2>/dev/null || break; sleep 0.25; done
            kill -0 "$n" 2>/dev/null && kill -TERM "$n" 2>/dev/null
        done
    done

    if [[ -n "$herdr_pid" ]]; then
        herdr session stop "$s" >/dev/null 2>&1
        for _ in $(seq 1 20); do kill -0 "$herdr_pid" 2>/dev/null || break; sleep 0.25; done
        # Children that outlived the server (agent helpers, MCP servers) were
        # recorded before the stop; SIGTERM any still alive.
        for line in "${herdr_procs[@]}"; do
            n=${line%% *}
            for _ in $(seq 1 8); do kill -0 "$n" 2>/dev/null || break; sleep 0.25; done
            if kill -0 "$n" 2>/dev/null; then
                kill -TERM "$n" 2>/dev/null
                leftover+=("$n")
            fi
        done
    fi

    printf 'stopped task %s\n' "$task"
    printf '  nvim: quit %s\n' "${#stopped[@]}"
    [[ ${#kept[@]} -eq 0 ]] || printf '  nvim kept open (unsaved buffers or a prompt): %s\n' "${kept[*]}"
    [[ -z "$herdr_pid" ]] || printf '  herdr: session %s stopped; agents ended: %s; workspaces kept: %s\n' "$s" "${#agents[@]}" "${#workspaces[@]}"
    [[ ${#leftover[@]} -eq 0 ]] || printf '  leftover processes sent SIGTERM: %s\n' "${leftover[*]}"
    printf '  kept: worktrees, branches, task files, tmux session %s and its shells\n' "$s"
}

stop_command() {
    local task=${1:-} dry=no force=no arg
    [[ -n "$task" ]] || die "usage: stop <task> [--dry-run] [--force]"
    valid_name "$task" || die "invalid task name: $task"
    shift
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry=yes ;;
            --force) force=yes ;;
            *) die "usage: stop <task> [--dry-run] [--force]" ;;
        esac
    done
    stop_task "$task" "$dry" "$force"
}

# --- fzf picker (terminal / tmux prefix key) ---------------------------------

fzf_repos() {
    list_repos | sed "s#^$HOME/#~/#" |
        fzf -m --prompt "$1> " --header 'tab: mark · enter: confirm' | sed "s#^~/#$HOME/#"
}

pick() {
    local out query key task="" branch="" t r kind value task_count=0 repos=()
    mkdir -p "$TASKS_DIR"
    out=$({
        while IFS= read -r t; do
            printf 'task\t%s\t%s %s  (%s)\n' "$t" "$ICON_TASK" "$t" "$(task_detail "$t")"
        done < <(list_tasks)
        while IFS= read -r r; do
            printf 'repo\t%s\t%s %s  %s\n' "$r" "$ICON_REPO" "$(basename "$r")" "$(dirname "${r/#$HOME/\~}")"
        done < <(list_repos)
    } | fzf -m --delimiter '\t' --with-nth 3 --print-query --expect=ctrl-a,ctrl-d,ctrl-r --prompt 'task or repo> ' \
        --header $'enter: open task, or start a task from marked repos\ntab: mark repos · ctrl-a: add to task · ctrl-r: repos of selected task · ctrl-d: close selected task · or type a new task name')
    query=$(sed -n 1p <<< "$out")
    key=$(sed -n 2p <<< "$out")
    while IFS=$'\t' read -r kind value _; do
        case "$kind" in
            task) [[ -n "$task" ]] || task=$value; task_count=$((task_count + 1)) ;;
            repo) repos+=("$value") ;;
        esac
    done < <(sed -n '3,$p' <<< "$out")

    if [[ "$key" == ctrl-d ]]; then
        [[ -n "$task" && $task_count -eq 1 && ${#repos[@]} -eq 0 ]] ||
            die "Ctrl-D closes one selected task; select exactly one task and no repos"
        close_task_terminal "$task"
        return
    fi

    if [[ "$key" == ctrl-r ]]; then
        [[ -n "$task" && $task_count -eq 1 && ${#repos[@]} -eq 0 ]] ||
            die "Ctrl-R works on one selected task; select exactly one task and no repos"
        repos_terminal "$task"
        return
    fi

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

# Terminal flow for one task's repos: pick a repo, then an action. Demote and
# remove show the --dry-run plan and ask before running.
repos_terminal() {
    local task=$1 rows sel name kind action dry_out
    local -a forcearg=()
    rows=$(task_repo_rows "$task")
    [[ -n "$rows" ]] || { echo "task $task has no repos"; return 0; }
    sel=$(awk -F '\t' '{ print $2 "\t" $3 }' <<< "$rows" |
        fzf --delimiter '\t' --with-nth 2 --prompt "repos in $task> ") || return 0
    name=${sel%%$'\t'*}
    kind=$(task_repo_lookup "$task" "$name" | cut -f1) || return 0
    if [[ "$kind" == context ]]; then
        action=$(printf 'promote\nremove\n' | fzf --prompt "$name (context)> ") || return 0
    else
        action=$(printf 'demote\nremove\n' | fzf --prompt "$name (worker)> ") || return 0
    fi
    if [[ "$action" == promote ]]; then
        "$SELF" promote "$task" "$name"
        return
    fi
    if dry_out=$("$SELF" "$action" "$task" "$name" --dry-run 2>&1); then
        printf '%s\n' "$dry_out"
    else
        printf '%s\n' "$dry_out"
        dry_out=$("$SELF" "$action" "$task" "$name" --dry-run --force 2>&1) || { printf '%s\n' "$dry_out" >&2; return 1; }
        forcearg=(--force)
        printf 'Forcing discards the uncommitted work shown above:\n%s\n' "$dry_out"
    fi
    confirm "Run $action $name in $task?" || return 0
    "$SELF" "$action" "$task" "$name" "${forcearg[@]}"
}

# --- Omarchy menu picker (desktop keybind) -----------------------------------

menu_task_rows() {
    local t
    while IFS= read -r t; do
        printf '%s\t%s\ttask: %s\n' "$ICON_TASK" "$t" "$(task_detail "$t")"
    done < <(list_tasks)
    printf '%s\t%s\taction:repos\n' "$ICON_REPO" "$REPOS_LABEL"
    printf '%s\t%s\taction:add\n' "$ICON_ADD" "$ADD_LABEL"
    printf '%s\t%s\taction:create\n' "$ICON_REPO" "$CREATE_LABEL"
    printf '%s\t%s\taction:close\n' "$ICON_CONTEXT" "$CLOSE_LABEL"
}

menu_existing_task_rows() {
    local t
    while IFS= read -r t; do
        printf '%s\t%s\ttask: %s\n' "$ICON_TASK" "$t" "$(task_detail "$t")"
    done < <(list_tasks)
}

menu_repo_rows() {
    local r
    while IFS= read -r r; do
        printf '%s\t%s\t%s\n' "$ICON_REPO" "$(basename "$r")" "${r/#$HOME/\~}"
    done
}

# Testable seams keep the actual menu flow covered without opening graphical UI.
menu_choose() {
    local title=$1 rows=$2 queue=${TASK_MENU_CHOICES_FILE:-} selected temporary selector_rows
    if [[ -n "$queue" ]]; then
        [[ -s "$queue" ]] || return 1
        IFS= read -r selected < "$queue"
        selector_rows=$(awk -F '\t' 'NF >= 2 { if (NF >= 3) print $2 "\t" $3; else print $2 }' <<< "$rows")
        grep -Fxq -- "$selected" <<< "$selector_rows" || {
            echo "task-sessionizer: fixture choice is not present in '$title' rows: $selected" >&2
            return 2
        }
        temporary="$queue.tmp.$$"
        tail -n +2 "$queue" > "$temporary"
        mv -f "$temporary" "$queue"
        printf '%s\n' "$selected"
        return 0
    fi
    [[ -n "$rows" ]] || return 1
    printf '%s\n' "$rows" | omarchy-menu-select "$title" -- --width 700
}

menu_input() {
    local title=$1 queue=${TASK_MENU_INPUTS_FILE:-} value temporary
    if [[ -n "$queue" ]]; then
        [[ -s "$queue" ]] || return 1
        IFS= read -r value < "$queue"
        temporary="$queue.tmp.$$"
        tail -n +2 "$queue" > "$temporary"
        mv -f "$temporary" "$queue"
        printf '%s\n' "$value"
        return 0
    fi
    omarchy-menu-input "$title" --width 700
}

repo_in_task() {
    local task=$1 repo=$2 wt origin name path
    while IFS= read -r wt; do
        origin=$(origin_repo "$wt")
        [[ "$origin" == "$repo" ]] && return 0
    done < <(task_worktrees "$task")
    while IFS=$'\t' read -r name path; do [[ "$path" == "$repo" ]] && return 0; done < <(task_contexts "$task")
    return 1
}

MENU_WORKERS=()
MENU_CONTEXTS=()

close_task_terminal() {
    local task=$1 out
    confirm "Close task $task? Its worktrees and sessions will be removed; branches stay" || return 0
    if out=$("$SELF" close "$task" 2>&1); then
        printf '%s\n' "$out"
        return 0
    fi
    printf '%s\n' "$out" >&2
    if [[ "$out" == *"use close $task --force"* ]] &&
        confirm "Force close $task? Uncommitted work/task-root files will be discarded; branches stay"; then
        "$SELF" close "$task" --force
    fi
}

close_task_menu() {
    local task=$1 issues rows selected action summary
    issues=$(task_close_issues "$task")
    if [[ -n "$issues" ]]; then
        summary=$(paste -sd '; ' <<< "$issues")
        rows=$(printf '%s\tForce close\t%s; worktrees and task-root data are removed, branches stay\n%s\tCancel\tLeave task unchanged' \
            "$ICON_CONTEXT" "$summary" "$ICON_DONE")
        selected=$(menu_choose "Close task $task?" "$rows") || return 0
        IFS=$'\t' read -r action _ <<< "$selected"
        [[ "$action" == "Force close" ]] || return 0
        "$SELF" close "$task" --force
    else
        rows=$(printf '%s\tClose task\tRemove worktrees and sessions; branches stay\n%s\tCancel\tLeave task unchanged' \
            "$ICON_DONE" "$ICON_CONTEXT")
        selected=$(menu_choose "Close task $task?" "$rows") || return 0
        IFS=$'\t' read -r action _ <<< "$selected"
        [[ "$action" == "Close task" ]] || return 0
        "$SELF" close "$task"
    fi
}

# Popup flow for one task's repo: pick it, then promote, demote or remove. Demote
# and remove show the dry-run plan as rows and run only after Run is chosen.
menu_task_repos() {
    local task=$1 rows sel name kind action verb dry_out line plan=""
    local -a forcearg=()
    rows=$(task_repo_rows "$task")
    [[ -n "$rows" ]] || return 0
    sel=$(menu_choose "Repos in $task" "$rows") || return 0
    IFS=$'\t' read -r name _ <<< "$sel"
    kind=$(task_repo_lookup "$task" "$name" | cut -f1) || return 0
    if [[ "$kind" == context ]]; then
        rows=$(printf '%s\tPromote\tmake a worker worktree and agent\n%s\tRemove\tdrop it from the task\n%s\tCancel\tdo nothing' \
            "$ICON_REPO" "$ICON_CONTEXT" "$ICON_DONE")
    else
        rows=$(printf '%s\tDemote\tremove the worktree; keep the branch\n%s\tRemove\tdemote, then drop it from the task\n%s\tCancel\tdo nothing' \
            "$ICON_REPO" "$ICON_CONTEXT" "$ICON_DONE")
    fi
    sel=$(menu_choose "$name in $task" "$rows") || return 0
    IFS=$'\t' read -r action _ <<< "$sel"
    case "$action" in
        Promote) "$SELF" promote "$task" "$name"; return ;;
        Demote) verb=demote ;;
        Remove) verb=remove ;;
        *) return 0 ;;
    esac
    local reason="" run_label="Run" title
    if ! dry_out=$("$SELF" "$verb" "$task" "$name" --dry-run 2>&1); then
        reason=$dry_out
        if dry_out=$("$SELF" "$verb" "$task" "$name" --dry-run --force 2>&1); then
            forcearg=(--force)
            run_label="Run (force: discards uncommitted work)"
        else
            notify-send "Task sessionizer" "$(head -n1 <<< "$reason")"
            return 0
        fi
    fi
    # A forced run shows the refusal it overrides as the first plan row.
    if [[ -n "$reason" ]]; then
        plan+=$(printf '%s\tplan\t%s\n' "$ICON_CONTEXT" "$(head -n1 <<< "$reason")")$'\n'
    fi
    while IFS= read -r line; do
        plan+=$(printf '%s\tplan\t%s\n' "$ICON_CONTEXT" "$line")$'\n'
    done <<< "$dry_out"
    rows="$plan$(printf '%s\t%s\t%s %s in %s' "$ICON_DONE" "$run_label" "$verb" "$name" "$task")"$'\n'
    rows+=$(printf '%s\tCancel\tkeep everything as it is' "$ICON_CONTEXT")
    title="${verb^} $name in $task? Plan shown above"
    [[ ${#forcearg[@]} -gt 0 ]] && title="Force ${verb} $name in $task? Discards uncommitted work; plan shown above"
    sel=$(menu_choose "$title" "$rows") || return 0
    IFS=$'\t' read -r action _ <<< "$sel"
    [[ "$action" == "$run_label" ]] || return 0
    "$SELF" "$verb" "$task" "$name" "${forcearg[@]}"
}

# Repeated single-select steps provide multi-select behavior with an explicit
# mode per repo. A repo remains selected after its Worker/Context choice.
menu_repo_picker() {
    local task=$1 prompt=$2 rows sel icon name display repo mode mode_rows
    local -A chosen=()
    MENU_WORKERS=()
    MENU_CONTEXTS=()
    while :; do
        rows=""
        if ((${#MENU_WORKERS[@]} + ${#MENU_CONTEXTS[@]})); then
            rows+=$(printf '%s\tDone\taction:done (%d worker, %d context)\n' "$ICON_DONE" "${#MENU_WORKERS[@]}" "${#MENU_CONTEXTS[@]}")$'\n'
        fi
        while IFS= read -r repo; do
            [[ -n "${chosen[$repo]:-}" ]] && continue
            repo_in_task "$task" "$repo" && continue
            rows+=$(printf '%s\t%s\t%s\n' "$ICON_REPO" "$(basename "$repo")" "${repo/#$HOME/\~}")$'\n'
        done < <(list_repos)
        sel=$(menu_choose "$prompt" "$rows") || return 1
        IFS=$'\t' read -r name display <<< "$sel"
        [[ "$display" == action:done* ]] && break
        repo=${display/#\~/$HOME}
        mode_rows=$(printf '%s\tWORKER\tCreate a task worktree, nvim/srv windows, and repo agent\n%s\tCONTEXT\tRead-only canonical checkout; no worktree or repo agent' "$ICON_REPO" "$ICON_CONTEXT")
        sel=$(menu_choose "Repo mode: $name" "$mode_rows") || return 1
        IFS=$'\t' read -r mode _ <<< "$sel"
        case "$mode" in
            WORKER) MENU_WORKERS+=("$repo"); chosen[$repo]=worker ;;
            CONTEXT) MENU_CONTEXTS+=("$repo"); chosen[$repo]=context ;;
            *) die "unknown repo mode: $mode" ;;
        esac
    done
    ((${#MENU_WORKERS[@]} + ${#MENU_CONTEXTS[@]} > 0))
}

pick_menu() {
    local sel label detail task input mode
    local -a selection=()
    mkdir -p "$TASKS_DIR"
    sel=$(menu_choose "Tasks" "$(menu_task_rows)") || return 0
    IFS=$'\t' read -r label detail <<< "$sel"
    case "$detail" in
        task:*) open_session "$label"; return ;;
        action:create)
            input=$(menu_input "Name for new task") || return 0
            task=$input
            valid_name "$task" || die "task name must match [A-Za-z0-9._-]+ (got '$task')"
            menu_repo_picker "$task" "Repos for $task" || return 0
            selection=()
            for mode in "${MENU_WORKERS[@]}"; do selection+=(--worker "$mode"); done
            for mode in "${MENU_CONTEXTS[@]}"; do selection+=(--context "$mode"); done
            create_task "$task" "${selection[@]}"
            ;;
        action:add)
            sel=$(menu_choose "Add repo to task" "$(menu_existing_task_rows)") || return 0
            IFS=$'\t' read -r task detail <<< "$sel"
            [[ "$detail" == task:* ]] || return 0
            menu_repo_picker "$task" "Repos to add to $task" || return 0
            selection=()
            for mode in "${MENU_WORKERS[@]}"; do selection+=(--worker "$mode"); done
            for mode in "${MENU_CONTEXTS[@]}"; do selection+=(--context "$mode"); done
            add_task_repos "$task" "${selection[@]}"
            ;;
        action:repos)
            sel=$(menu_choose "Task for repos" "$(menu_existing_task_rows)") || return 0
            IFS=$'\t' read -r task detail <<< "$sel"
            [[ "$detail" == task:* ]] || return 0
            menu_task_repos "$task"
            return
            ;;
        action:close)
            sel=$(menu_choose "Task to close" "$(menu_existing_task_rows)") || return 0
            IFS=$'\t' read -r task detail <<< "$sel"
            [[ "$detail" == task:* ]] || return 0
            close_task_menu "$task"
            return
            ;;
        *) return 0 ;;
    esac
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
    *:create)
        shift
        [[ $# -ge 3 ]] || die "usage: create <task> --worker repo|--context repo [...]"
        task=$1
        shift
        create_task "$task" "$@"
        ensure_task_runtime "$task"
        dispatch_hooks "$task"
        ;;
    *:add)
        shift
        [[ $# -gt 0 ]] || die "usage: add <task> [repo..]"
        task=$1
        shift
        if [[ $# -eq 0 ]]; then
            mapfile -t picked < <(fzf_repos "add to $task")
            ((${#picked[@]})) || exit 0
            set -- "${picked[@]}"
        fi
        add_task_repos "$task" "$@"
        dispatch_hooks "$task"
        ;;
    *:promote)
        [[ $# -eq 3 ]] || die "usage: promote <task> <repo>"
        promote_context "$2" "$3"
        ;;
    *:demote) shift; repo_command demote "$@" ;;
    *:remove) shift; repo_command remove "$@" ;;
    *:close)
        [[ $# -ge 2 && $# -le 3 ]] || die "usage: close <task> [--force]"
        close_task "$2" "${3:-}"
        ;;
    *:stop) shift; stop_command "$@" ;;
    *:list) list_task_resources ;;
    *:sessions) [[ "${2:-}" == popup ]] && TASK_POPUP=1; pick_session ;;
    # Used by the task picker and task/session menu rows.
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
