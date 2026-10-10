# Personal dotfiles

Selected configuration for zsh, Hyprland, Omarchy, Ghostty, tmux (including
the task sessionizer), and herdr. The active home remains the runtime copy.

This repo appears in the task sessionizer under `~/personal/projects`.
Create a task or add `dotfiles` to an existing task to edit an isolated worktree.

From that worktree:

```sh
python3 scripts/dotfiles.py plan
python3 scripts/dotfiles.py apply
```

Apply copies tracked `.config/` files and `.zshrc` into the home and stores
replaced files under `~/.local/state/dotfiles/backups/<timestamp>/`.
Use `--home /tmp/test-home` to preview or test against another home.
Unrelated files are retained. File deletions require separate handling.
Capture later runtime changes by copying the selected files back into the
worktree and reviewing `git diff`; never copy all of `.config` indiscriminately.

Hyprland Lua changes need `hyprctl reload` and `hyprctl configerrors` after
deployment. Other programs may need their own reload or restart.
Omarchy itself is a separate source repo; personal settings belong here.
No Git remote is configured and nothing is pushed.
