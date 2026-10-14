#!/usr/bin/env bash
set -euo pipefail

mode=dry-run
case "${1:-}" in
	"") ;;
	--apply) mode=apply ;;
	-h|--help)
		cat <<'EOF'
Usage: migrate-home-layout.sh [--apply]

Default mode prints planned same-filesystem moves and rollback commands.
--apply performs the preflighted moves and repairs/verifies Git task worktrees.
EOF
		exit 0
		;;
	*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf 'Too many arguments\n' >&2; exit 2; }

personal="$HOME/personal"
workspace="$HOME/workspace"
projects="$HOME/Projects"
work="$HOME/Work"
documents="$HOME/Documents"
tasks="$HOME/tasks"

declare -a sources=() destinations=() kinds=()
add_move() {
	local source="$1" destination="$2" kind="$3"
	[[ -e "$source" || -L "$source" ]] || return 0
	sources+=("$source")
	destinations+=("$destination")
	kinds+=("$kind")
}

shopt -s nullglob
for source in "$personal/projects"/*/; do
	[[ -d "$source" ]] || continue
	name="${source%/}"; name="${name##*/}"
	add_move "${source%/}" "$projects/$name" repo
done
add_move "$personal/neovim" "$projects/neovim" repo
add_move "$personal/rustlings" "$projects/rustlings" repo
for source in "$workspace/projects"/*/; do
	[[ -d "$source" ]] || continue
	name="${source%/}"; name="${name##*/}"
	add_move "${source%/}" "$work/$name" repo
done
for source in "$personal"/*.apkg "$personal"/NFSe*.pdf "$personal/Library of Ohara"; do
	add_move "$source" "$documents/${source##*/}" document
done
shopt -u nullglob

if ((${#sources[@]} == 0)); then
	printf 'No planned home-layout moves found.\n'
	exit 0
fi

nearest_existing_dir() {
	local path="$1"
	while [[ ! -d "$path" ]]; do path="$(dirname -- "$path")"; done
	printf '%s\n' "$path"
}

discover_git_roots() {
	local base="$1" marker candidate top temp
	REPO_ROOTS=()
	if top="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null)" && [[ "$(realpath -e -- "$top")" == "$(realpath -e -- "$base")" ]]; then
		REPO_ROOTS+=("$base")
	fi
	temp="$(mktemp)" || return 1
	if ! find "$base" -mindepth 1 -name .git -prune -print0 > "$temp"; then
		rm -f -- "$temp"
		return 1
	fi
	while IFS= read -r -d '' marker; do
		candidate="${marker%/.git}"
		[[ -d "$candidate" ]] || continue
		top="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)" || continue
		[[ "$(realpath -e -- "$top")" == "$(realpath -e -- "$candidate")" ]] || continue
		local seen=0 existing
		for existing in "${REPO_ROOTS[@]}"; do [[ "$existing" == "$candidate" ]] && seen=1; done
		(( seen )) || REPO_ROOTS+=("$candidate")
	done < "$temp"
	rm -f -- "$temp"
}

repair_repository_tree() {
	local base="$1" repo output path
	local -a task_worktrees=()
	discover_git_roots "$base" || { printf 'Could not discover nested Git repositories under %s\n' "$base" >&2; return 1; }
	for repo in "${REPO_ROOTS[@]}"; do
		output="$(git -C "$repo" worktree list --porcelain)" || {
			printf 'Could not list worktrees for %s\n' "$repo" >&2; return 1;
		}
		task_worktrees=()
		while IFS= read -r path; do
			[[ "$path" == "$tasks"/* && -d "$path" ]] && task_worktrees+=("$path")
		done < <(sed -n 's/^worktree //p' <<< "$output")
		if ((${#task_worktrees[@]})); then git -C "$repo" worktree repair "${task_worktrees[@]}"; fi
		git -C "$repo" worktree list --porcelain >/dev/null
		for path in "${task_worktrees[@]}"; do git -C "$path" status --short >/dev/null; done
		printf 'Verified Git worktrees: %s\n' "$repo"
	done
}

printf 'Home layout migration (%s)\n' "$mode"
printf '  Personal repositories -> %s/\n' "$projects"
printf '  Work repositories -> %s/\n' "$work"
printf '  Selected loose personal files -> %s/\n' "$documents"
printf '  Preserved: %s/dev, %s, %s/tries and %s/.mise.toml\n' "$personal" "$tasks" "$work" "$work"

# Validate the complete plan before the first move.
for i in "${!sources[@]}"; do
	source="${sources[$i]}"; destination="${destinations[$i]}"
	[[ -e "$source" || -L "$source" ]] || { printf 'Source disappeared: %s\n' "$source" >&2; exit 1; }
	if [[ -e "$destination" || -L "$destination" ]]; then
		printf 'Destination already exists; refusing migration: %s\n' "$destination" >&2
		exit 1
	fi
	source_dev="$(stat -c %d -- "$source")"
	destination_parent="$(nearest_existing_dir "$(dirname -- "$destination")")"
	destination_dev="$(stat -c %d -- "$destination_parent")"
	[[ "$source_dev" == "$destination_dev" ]] || {
		printf 'Cross-filesystem move refused: %s -> %s\n' "$source" "$destination" >&2
		exit 1
	}
done

printf 'Preflight passed: %d moves, no destination collisions, all on the source filesystem.\n' "${#sources[@]}"
printf 'Apply also discovers every nested Git root within each moved repository and repairs its registered ~/tasks worktrees.\n'
for i in "${!sources[@]}"; do
	source="${sources[$i]}"; destination="${destinations[$i]}"
	printf '  mv -- %q %q\n' "$source" "$destination"
done
if [[ -d "$personal/projects" ]]; then
	for path in "$personal/projects"/* "$personal/projects"/.[!.]*; do
		[[ -e "$path" || -L "$path" ]] || continue
		[[ -d "$path" ]] && continue
		printf '  Review (left in place): %s\n' "$path"
	done
fi
printf '\nRollback commands (if apply completes):\n'
for i in "${!sources[@]}"; do
	source="${sources[$i]}"; destination="${destinations[$i]}"
	printf '  mkdir -p -- %q && mv -n -- %q %q\n' "$(dirname -- "$source")" "$destination" "$source"
done

if [[ "$mode" == dry-run ]]; then
	printf '\nDry run only; no files moved.\n'
	exit 0
fi

for i in "${!sources[@]}"; do
	source="${sources[$i]}"; destination="${destinations[$i]}"
	kind="${kinds[$i]}"
	mkdir -p -- "$(dirname -- "$destination")"
	mv -T -- "$source" "$destination"
	printf 'Moved: %s -> %s\n' "$source" "$destination"
	if [[ "$kind" == repo ]]; then repair_repository_tree "$destination"; fi
done

dotfiles_root="$projects/dotfiles"
if [[ -d "$dotfiles_root" ]]; then
	if [[ -x "$dotfiles_root/scripts/envctl" && -x "$dotfiles_root/scripts/sync.sh" && -f "$dotfiles_root/env/.zshrc" ]]; then
		grep -Fq "alias dev='~/Projects/dotfiles/scripts/envctl'" "$dotfiles_root/env/.zshrc" || {
			printf 'The deployed dev alias does not resolve to the moved canonical checkout.\n' >&2; exit 1;
		}
		grep -Fq "alias sync='~/Projects/dotfiles/scripts/sync.sh'" "$dotfiles_root/env/.zshrc" || {
			printf 'The deployed sync alias does not resolve to the moved canonical checkout.\n' >&2; exit 1;
		}
	else
		printf 'Could not verify envctl/sync aliases in %s\n' "$dotfiles_root" >&2
		exit 1
	fi
	printf 'Verified envctl and sync aliases resolve in %s/env/.zshrc\n' "$dotfiles_root"

	task_sessionizer="$dotfiles_root/env/.config/tmux/scripts/task-sessionizer.sh"
	if [[ -x "$task_sessionizer" ]]; then
		repo_list="$("$task_sessionizer" list-repos)"
		for i in "${!destinations[@]}"; do
			destination="${destinations[$i]}"
			if [[ "${kinds[$i]}" == repo ]] && git -C "$destination" rev-parse --show-toplevel >/dev/null 2>&1; then
				grep -Fxq "$destination" <<< "$repo_list" || {
					printf 'Task sessionizer did not discover moved repo: %s\n' "$destination" >&2; exit 1;
				}
			fi
		done
		printf 'Verified task sessionizer discovers moved repositories.\n'
	else
		printf 'Could not verify task-sessionizer repo discovery: %s\n' "$task_sessionizer" >&2
		exit 1
	fi
fi

# Remove only empty legacy parents; these commands never remove files.
rmdir -- "$personal/projects" 2>/dev/null || true
rmdir -- "$workspace/projects" 2>/dev/null || true
rmdir -- "$workspace" 2>/dev/null || true
rmdir -- "$personal" 2>/dev/null || true
printf 'Migration complete. No source files were deleted.\n'
