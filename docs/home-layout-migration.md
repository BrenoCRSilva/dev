# Home layout migration plan

Worktree-only changes. `scripts/migrate-home-layout.sh` defaults to dry-run;
the orchestrator runs `--apply` only after reviewing the destinations. The
script preflights every source, destination collision, and filesystem device
before the first move. It uses `mv`, discovers the moved repository and all
nested Git roots, repairs each root's worktrees under `~/tasks`, checks each
worktree with `git status`, prints rollback commands, and only attempts `rmdir`
on empty legacy parents. It never deletes a file.

## Dry-run inventory from 2026-10-14

Personal repositories to `~/Projects/`:

- DankMaterialShell
- HyprPanel
- one additional personal repository
- advent-of-code
- dotfiles
- hyprdots
- uni
- neovim
- rustlings

Work repositories to `~/Work/`:

- raid-notifier
- talqui-chat
- talqui-scratch

Loose files/folder to `~/Documents/`:

- `1_to_20_Multiplication_Tables_100_accurate_value.apkg`
- `Ultimate_Geography_v53.apkg`
- `rust-anki.apkg`
- `NFSe_492175_12.pdf`
- `Library of Ohara/`

The dry run found `~/personal/projects/.gitignore`, which is not a repository
and is left in place for review. It also preserves `~/personal/dev` as the
retired legacy checkout, `~/tasks`, `~/Work/tries`, and `~/Work/.mise.toml`.
The live dry run passed preflight for 17 moves: every destination was absent
and every source/destination pair resolves to the same filesystem. The
checked-in fixture exercises collisions, no-op planning, move behavior,
task-worktree repair, and rollback-command presence without moving the user's
home data. The fixture includes both a moved repository and a nested repository,
each with its own task worktree. Git emits its broken `.git` pointer notice
while repairing those fixtures; `worktree list` and `git status` both succeed
after repair.

## Authored path updates

Updated the canonical checkout guard and aliases/completion to
`~/Projects/dotfiles`; task/repo discovery now searches `~/Projects` and
`~/Work`. The tmux extra-directory list, old sessionizer, README, and fixture
paths follow the new roots. `.zshrc` now exports `XDG_PROJECTS_DIR=$HOME/Projects`.
In interactive Zsh, `try init ~/Work/tries` runs only if `try` is an executable
and neither an alias nor a function already owns that name. The existing
`~/Work/.mise.toml` adds `./bin` to PATH for commands from `~/Work`.

Read-only live search outside `env/` found these old-path records. No live
configuration was edited by this task. The managed `.zshrc` and tmux
scripts/directories references have matching worktree updates. Two unmanaged
files still contain references: `~/.config/tmux-sessionizer/directories` and
`~/.codex/config.toml` (three matches); neither is rewritten.

The scan found 15 Claude Code project-history directory names, seven old-root
references in `~/.claude.json`, and no old-root references in Claude settings
files. Codex config and application history/trust/session metadata are left
alone. No matching references were found in `.local/bin`, user systemd units,
desktop entries, DBus desktop services, zoxide's database, global Git
`safe.directory`, tmux live pane working directories, Herdr config/session
state, GTK bookmarks, or the scanned `~/.config/strata` files. Common
`~/.config/Code`, `~/.config/Cursor`, and `~/.config/VSCodium` roots were not
present, so editor recent-workspace databases were not inspected. Neovim
ShaDa is binary history/state and is not rewritten; old paths may remain as
inert history. VS Code/Cursor recent-workspace databases, Strata bookmarks,
lazygit/gh state, and mise trust are not rewritten by this script. A
task-sessionizer `.bak.*` copy is not authored config and is excluded from
rewrites/capture.

The `.git` pointer scan found old-root references in task worktrees, including
this task's dotfiles and companion-repository worktrees. On apply, the script
discovers each moved repository plus nested `.git` roots, runs
`git worktree repair` for their task-worktree paths, then checks `git worktree list` and each task worktree's
`git status`. It does not rewrite task metadata or pointers for repositories
that are not moved. Existing tmux sessions retain their cwd. No compatibility
symlinks are created: authored references are updated and Git repair is
preferred. The migration fixture's Git repair emits a broken-pointer notice
while repairing, but subsequent worktree list and status checks succeed.

## Display-panel persistence (worktree only)

The Omarchy scale panel persists scale by replacing the exact local variable
declarations in the host `monitors.lua`; autoreload then reapplies that file.
The authored host override sets `omarchy_monitor_scale = 1.25` and
`omarchy_gdk_scale = 1`, positions DP-2 at `0x0` and HDMI-A-1 at
`floor(2560/1.25) = 2048x0`, and keeps HDMI-A-1 at scale 1 with transform 3.
Ghostty font-size is 12 at this 1.25 compositor scale, preserving the prior
approximately 15-point physical size. The shell text baseline is the user's
selected stock value `[font] base-size = 12`.

The stock `omarchy-display-text-size` maps terminal points to
`round(px * 9 / 12)`: 12px resets Ghostty to 9pt, while 16px maps to 12pt.
Thus the current values honor the requested 12px UI baseline and 12pt
Ghostty font at scale 1.25, but using the Omarchy text-size panel at 12px
would change Ghostty to 9pt. Keeping 12pt through that panel requires a 16px
global setting, which differs from the selected 12px baseline. No stock
script or mapping was changed; confirm whether the 12px global baseline takes
priority over the panel's terminal mapping before deployment.
