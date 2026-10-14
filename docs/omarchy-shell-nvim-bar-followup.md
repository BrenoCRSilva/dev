# Omarchy shell, Neovim, and bar follow-up

**Checked:** 2026-10-13 against installed Omarchy `4.0.4-1` and Neovim
`0.12.5-1`. The authored owner is `env/` in this repository; these latest
follow-up edits remain worktree-only until separately deployed.

## Shell

Installed stock Bash initialization under `/usr/share/omarchy/default/bash`
starts mise, Starship, zoxide and fzf integrations, with history search and
completion helpers. The authored Zsh keeps Zinit and Powerlevel10k, initializes
zoxide, completion, syntax highlighting, autosuggestions and fzf-tab. It now
also activates mise and fzf's supported widgets while preserving existing
Ctrl-T/Ctrl-R and fzf-tab bindings; fzf file/history widgets use unused
Alt-F/Alt-H bindings in vi maps. The generated `shell-colors.zsh` input feeds
fzf and p10k from Omarchy's selected theme. Starship was not substituted for
the user's p10k prompt.

## Neovim

The installed `/etc/skel/.config/nvim` starter uses LazyVim. The personal
`env/.config/nvim` setup already provides Telescope, Neo-tree, Oil, Trouble,
Conform, Mason/LSP, Treesitter, Blink, Lualine, Noice/notify and Git tools, so
the starter does not justify replacing the personal plugin stack.

The useful stock remote-clipboard behavior is adapted in
`lua/brenocrs/remote_clipboard.lua`: local Wayland behavior remains; remote,
tmux and Herdr ancestry select an available OSC52/Wayland transport with
fallbacks. Theme state follows the personal Omarchy palette schema and the
single theme-set hook in `env/.config/omarchy/hooks/`.

## Bar and theme flow

The user shell selects its widget layout in `env/.config/omarchy/shell.json`;
theme-generated values come from Omarchy's current-theme files. User
`env/.config/omarchy/shell.toml` contains only horizontal bar geometry, so
stock-generated color tokens remain inherited. Workspaces and system monitor
use a faint `Color.bar.background` tint; monitor text and normal glyphs share
the bar foreground. The entire bar remains transparent, and theme changes
recolor these surfaces without changing widget placement.

The authored shell QML uses Omarchy `Color` values for surfaces, accents and
urgent states. The full source-by-source exception list is in
[`theme-source-audit.md`](theme-source-audit.md).
