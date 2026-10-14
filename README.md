# Personal dotfiles

This repository's origin is `git@github.com:BrenoCRSilva/dev.git`.

`env/` is the single authored mirror for zsh, Powerlevel10k, Hyprland, Omarchy,
Ghostty, tmux, and Neovim. The Neovim configuration is owned here at
`env/.config/nvim`; the separate `neovimrc` repository is retired. The active
home remains the runtime copy. Hardware
specific Hyprland input and monitor settings live in `env/hosts/` overlays.

Every task, including a single-repo task, has a task-root herdr workspace for the orchestrator and one workspace per repo. Choose the orchestrator provider at the task root; it starts missing repo agents. Reopening an older task adds the missing orchestrator workspace without replacing repo panes.

This repo appears in the task sessionizer under `~/Projects`. Personal repos
live in `~/Projects/<name>`, and work repos in `~/Work/<name>`; `~/Work/tries`
and `~/tasks` are separate. `scripts/migrate-home-layout.sh` previews this
home-directory move by default; review its paths and rollback commands before
running it with `--apply`.
Create a task or add `dotfiles` to an existing task to edit an isolated worktree.

From that worktree:

```sh
scripts/envctl plan apply --host omarchy-workstation
scripts/envctl apply --dry-run --host omarchy-workstation
scripts/envctl apply --host omarchy-workstation
scripts/envctl plan capture --host omarchy-workstation
scripts/envctl capture --host omarchy-workstation
scripts/envctl diff --host omarchy-workstation
scripts/envctl backup --host omarchy-workstation
scripts/envctl restore ~/.local/state/dotfiles/backups/omarchy-workstation/apply-<timestamp>
```

`env/dotfiles.manifest` is the deployment allowlist. `apply` and `capture` make
timestamped backups; `--dry-run` and `plan <action>` show previews. `diff` emits
unified content differences. `backup` snapshots currently managed home paths.
Apply does not delete files; explicit `prune` requires paths previously managed
and saves them before deletion. Restore reinstates replacements/deletions and
removes paths that were newly created by the operation.
Generated theme state, Neovim caches/plugins, credentials, sessions, and
backup files are excluded. Custom Omarchy themes and
overlays are included when present; external stock-theme symlinks are skipped.
Snapshots live under `${XDG_STATE_HOME:-~/.local/state}/dotfiles` with private
directory permissions; `DOTFILES_STATE_DIR` can override this for fixtures.
`scripts/dotfiles.py` and `scripts/apply.sh`/`capture.sh` are compatibility
entry points. Run `scripts/sync.sh` from the canonical checkout
`~/Projects/dotfiles`; it is guarded to that checkout on `main`,
captures host `omarchy-workstation`, commits as `automated dev commit`, and
pushes to `origin main`.

Hyprland Lua changes need `hyprctl reload` and `hyprctl configerrors` after
deployment. Other programs may need their own reload or restart.
Omarchy itself is a separate source repo; personal settings belong here.
