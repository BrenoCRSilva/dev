# Personal dotfiles

`env/` is the single authored mirror for zsh, Powerlevel10k, Hyprland, Omarchy,
Ghostty, tmux, and Neovim. The active home remains the runtime copy. Hardware
specific Hyprland input and monitor settings live in `env/hosts/` overlays.

This repo appears in the task sessionizer under `~/personal/projects`.
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
scripts/envctl sync "Update authored config"
scripts/envctl sync "Update authored config" --push
```

`env/dotfiles.manifest` is the deployment allowlist. `apply` and `capture` make
timestamped backups; `--dry-run` and `plan <action>` show previews. `diff` emits
unified content differences. `backup` snapshots currently managed home paths.
Apply does not delete files; explicit `prune` requires paths previously managed
and saves them before deletion. Restore reinstates replacements/deletions and
removes paths that were newly created by the operation.
Generated theme state, Neovim caches/plugins, credentials, sessions, and
PontuArch service configuration are excluded. Custom Omarchy themes and
overlays are included when present; external stock-theme symlinks are skipped.
Snapshots live under `${XDG_STATE_HOME:-~/.local/state}/dotfiles` with private
directory permissions; `DOTFILES_STATE_DIR` can override this for fixtures.
`scripts/dotfiles.py` and `scripts/apply.sh`/`capture.sh`/`sync.sh` are
compatibility entry points. `sync [message]` commits already-reviewed
Git changes locally without capturing; `--push` is required to publish.

Hyprland Lua changes need `hyprctl reload` and `hyprctl configerrors` after
deployment. Other programs may need their own reload or restart.
Omarchy itself is a separate source repo; personal settings belong here.
No remote push is performed.
