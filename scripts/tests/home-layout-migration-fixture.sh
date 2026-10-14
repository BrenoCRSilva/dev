#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
mkdir -p "$home/personal/projects/example" "$home/personal/dev" \
	"$home/personal/projects/dotfiles/scripts" \
	"$home/personal/projects/dotfiles/env/.config/tmux/scripts" \
	"$home/workspace/projects/work-repo" "$home/tasks/task" \
	"$home/Work/tries" "$home/Documents"
export HOME="$home"

cp "$repo/scripts/envctl" "$repo/scripts/sync.sh" "$home/personal/projects/dotfiles/scripts/"
cp "$repo/env/.config/tmux/scripts/task-sessionizer.sh" "$home/personal/projects/dotfiles/env/.config/tmux/scripts/"
cat > "$home/personal/projects/dotfiles/env/.zshrc" <<'EOF'
alias dev='~/Projects/dotfiles/scripts/envctl'
alias sync='~/Projects/dotfiles/scripts/sync.sh'
EOF
chmod +x "$home/personal/projects/dotfiles/scripts/"* \
	"$home/personal/projects/dotfiles/env/.config/tmux/scripts/task-sessionizer.sh"

git -C "$home/personal/projects/example" init -q
git -C "$home/personal/projects/example" config user.name Fixture
git -C "$home/personal/projects/example" config user.email fixture@example.invalid
printf 'tracked\n' > "$home/personal/projects/example/tracked.txt"
git -C "$home/personal/projects/example" add tracked.txt
git -C "$home/personal/projects/example" commit -qm initial
git -C "$home/personal/projects/example" worktree add -q -b task-branch "$home/tasks/task/example"

# A moved checkout may contain an independent nested repository with its own
# task worktree; migration must repair both repository registries.
mkdir -p "$home/personal/projects/example/nested-repo"
git -C "$home/personal/projects/example/nested-repo" init -q
git -C "$home/personal/projects/example/nested-repo" config user.name Fixture
git -C "$home/personal/projects/example/nested-repo" config user.email fixture@example.invalid
printf 'nested tracked\n' > "$home/personal/projects/example/nested-repo/tracked.txt"
git -C "$home/personal/projects/example/nested-repo" add tracked.txt
git -C "$home/personal/projects/example/nested-repo" commit -qm initial
git -C "$home/personal/projects/example/nested-repo" worktree add -q -b nested-task "$home/tasks/task/nested-example"

printf 'keep for review\n' > "$home/personal/projects/.gitignore"
printf 'keep legacy\n' > "$home/personal/dev/README"
printf 'move me\n' > "$home/personal/notes.apkg"

preview="$("$repo/scripts/migrate-home-layout.sh")"
[[ "$preview" == *'Dry run only; no files moved.'* ]]
[[ -d "$home/personal/projects/example" && ! -e "$home/Projects/example" ]]
[[ "$preview" == *'Review (left in place): '*'/personal/projects/.gitignore'* ]]

"$repo/scripts/migrate-home-layout.sh" --apply > "$tmp/apply.out"
[[ -d "$home/Projects/example" && ! -e "$home/personal/projects/example" ]]
[[ -d "$home/Work/work-repo" && ! -e "$home/workspace/projects/work-repo" ]]
[[ -f "$home/Documents/notes.apkg" ]]
[[ -f "$home/personal/projects/.gitignore" && -f "$home/personal/dev/README" ]]
git -C "$home/Projects/example" worktree list >/dev/null
git -C "$home/tasks/task/example" status --short >/dev/null
git -C "$home/Projects/example/nested-repo" worktree list >/dev/null
git -C "$home/tasks/task/nested-example" status --short >/dev/null
grep -Fq 'Verified Git worktrees: '"$home/Projects/example/nested-repo" "$tmp/apply.out"

collision_home="$tmp/collision-home"
mkdir -p "$collision_home/personal/projects/blocked" "$collision_home/Projects/blocked"
if HOME="$collision_home" "$repo/scripts/migrate-home-layout.sh" > "$tmp/collision.out" 2>&1; then
	printf 'expected an existing destination to block migration\n' >&2
	exit 1
fi
[[ -d "$collision_home/personal/projects/blocked" ]]
[[ "$(cat "$tmp/collision.out")" == *'Destination already exists'* ]]

printf 'home layout migration fixture passed\n'
