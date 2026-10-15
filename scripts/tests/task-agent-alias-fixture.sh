#!/usr/bin/env bash
# Deploys the task-agent alias with envctl into a temporary HOME, then runs it
# through the deployed symlink. The dry run must read the role files from the
# deployed task-roles folder, so ROLES_DIR resolves through the symlink.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$tmp"' EXIT
root="$tmp/repo"
home="$tmp/home"
state="$tmp/state"
mkdir -p "$root/scripts" "$root/env/.local" "$root/env/.config/tmux/scripts" "$home"
cp "$repo/scripts/envctl" "$root/scripts/envctl"
cp "$repo/scripts/omarchy-theme-install-list.tsv" "$root/scripts/omarchy-theme-install-list.tsv"
cp -a "$repo/env/.local/bin" "$root/env/.local/bin"
cp -a "$repo/env/.config/tmux/scripts/." "$root/env/.config/tmux/scripts/"
printf '.local/bin/task-agent\n.config/tmux/scripts\n' > "$root/env/dotfiles.manifest"
run() { DOTFILES_ROOT="$root" DOTFILES_HOME="$home" DOTFILES_STATE_DIR="$state" "$root/scripts/envctl" "$@"; }

run apply > "$tmp/apply.out"
[[ -L "$home/.local/bin/task-agent" ]] || { echo "task-agent was not deployed as a symlink" >&2; exit 1; }
[[ "$(readlink "$home/.local/bin/task-agent")" == ../../.config/tmux/scripts/task-agent.sh ]] \
    || { echo "unexpected symlink target: $(readlink "$home/.local/bin/task-agent")" >&2; exit 1; }

# The dry run prints the launch command and needs no herdr pane (only the reports and trust lines warn).
out="$(HOME="$home" "$home/.local/bin/task-agent" --dry-run start researcher x 2> "$tmp/alias.err")" \
    || { cat "$tmp/alias.err" >&2; echo "alias dry run failed" >&2; exit 1; }
grep -q -- "--append-system-prompt-file $home/.config/tmux/scripts/task-roles/researcher.md" <<< "$out" \
    || { echo "alias did not resolve role files in the deployed folder: $out" >&2; exit 1; }
grep -q -- "--settings $home/.config/tmux/scripts/task-roles/researcher.claude-settings.json" <<< "$out" \
    || { echo "alias did not resolve settings in the deployed folder: $out" >&2; exit 1; }
echo "PASS: task-agent alias deploys as a symlink and resolves its role folder"
