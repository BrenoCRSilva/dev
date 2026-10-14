# Implementation status

The dotfiles worktree owns the authored configuration under `env/` and the
`scripts/envctl` capture/apply workflow. The latest theme-source and neutral
module-name changes are worktree-only; they have not been deployed. Existing
live configuration was not modified during this pass.

## Theme integration

Omarchy's selected theme and generated files under
`~/.local/state/omarchy/current/theme/` are the color source. Neovim reads the
generated personal palette schema through `lua/omarchy-colors.lua`; the
theme-set hook reloads existing Neovim servers through `lua/omarchy-theme.lua`.
Ghostty consumes Omarchy's generated `ghostty.conf`, Zsh and fzf consume the
small user template `shell-colors.zsh.tpl`, QML uses Omarchy `Color` tokens,
and tmux uses terminal ANSI names. Details and justified exceptions are in
[`theme-source-audit.md`](theme-source-audit.md).

The worktree removes the old static terminal palettes and duplicated Omarchy
templates. `env/.config/omarchy/shell.toml` retains only personal bar geometry;
stock generated theme colors remain inherited. The selected
`rose-pine-dark/colors.toml` remains the authored palette for that selectable
Omarchy theme.

## Workflow

`scripts/sync.sh` delegates to guarded `envctl sync`. Sync is restricted to
the canonical checkout on `main`, captures the configured host, commits with
`automated dev commit`, and pushes `origin main`. The `sync` and `dev` Zsh
aliases target the canonical checkout; the obsolete setup alias and old
checkout completion have been removed.

## Verification status

Passed: envctl capture/apply/sync fixture (including fake-Git contract),
Neovim theme adapter, remote clipboard contexts, Bash/Zsh syntax, and a static
tmux ANSI source check. A full tmux server could not start because sandbox
socket access is denied. The theme-hook fixture likewise could not start its
socket-backed Neovim instances.

Existing full-startup smoke reports a packaged Tree-sitter query field error
(`operator`) and denied parser/plugin writes; the LSP integration fixture
reports that `lua_ls` exits before attaching. These are recorded as unresolved
environment/config issues, not as successful checks. No live apply, theme
switch, service restart, or remote push was performed for this worktree pass.
