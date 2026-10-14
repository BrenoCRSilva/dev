# Omarchy shell, Neovim, and bar follow-up

**Checked:** 2026-10-13  
**Installed baseline:** Omarchy `4.0.4-1`, Neovim `0.12.5-1`, Gruvbox.

This supplements [the integration audit](omarchy-integration-audit.md). It describes the installed package and deployed personal config; the PontuArch plugin ecosystem shortlist is in [omarchy-plugin-integration-review.md](../../PontuArch/docs/omarchy-plugin-integration-review.md).

## Shell: Omarchy Bash versus the active Zsh

Omarchy’s `/usr/share/omarchy/default/bash/init` initializes `mise`, Starship, zoxide, and fzf’s Bash completion and key bindings. Its Bash shell files also set a 32,768-line history, append history, and configure completion and history search. `/usr/share/omarchy/default/bash/aliases` adds a zoxide-backed `cd` and file-picker helpers.

The deployed `env/.zshrc` uses Zinit, Powerlevel10k and the user’s `~/.p10k.zsh`; syntax highlighting, completions, autosuggestions, `fzf-tab`, and the Oh My Zsh Git plugin are loaded. It initializes zoxide with `--cmd cd`, sets a 5,000-line shared/appended history, and configures fuzzy completion previews. Installed `fzf`, `zoxide`, `mise`, and `starship` are available. Zsh does **not** initialize `mise`, source fzf’s explicit key-binding/completion scripts, or use Starship. `fzf-tab` improves completion selection but is not the same integration as fzf’s Ctrl-R/Ctrl-T/Alt-C bindings. `direnv` is not installed and is not part of Omarchy’s Bash init.

Useful optional additions, preserving Zsh and p10k:

1. Add `eval "$(mise activate zsh)"` if project-scoped tool versions are wanted; this is the documented Zsh activation route ([mise activation docs](https://mise.jdx.dev/cli/activate.html)).
2. Add fzf’s supported Zsh integration if its stock key bindings and completion are wanted; first check current Zinit/fzf-tab bindings for conflicts ([fzf shell integration docs](https://github.com/junegunn/fzf#setting-up-shell-integration)).
3. Consider a larger `HISTSIZE` (Omarchy Bash uses 32,768) and selected Omarchy file-picker aliases if useful. These are preference changes, not missing desktop integration.

No Starship migration is recommended by this audit; the user’s p10k setup is present and intentional.

## Neovim: useful stock pieces, without adopting LazyVim

`/etc/skel/.config/nvim` is the installed Omarchy starter, based on LazyVim. The active personal config is a separate Lazy.nvim setup authored and deployed from the canonical `env/.config/nvim` tree in this dotfiles repo. PontuArch's older `env/.config/nvim` copy is retained as a reference, not the current owner. The canonical plugin import chain already supplies Telescope, Neo-tree, Oil, Trouble, Conform, Mason/LSP, Treesitter, Blink, Lualine, Noice/notify, and Git tools. There is no clear reason to replace that setup with LazyVim or add duplicate explorer, picker, LSP, formatting, or statusline layers.

Three-to-five concrete stock ideas and how they compare:

1. **Remote clipboard — strongest candidate.** Stock `/etc/skel/.config/nvim/lua/config/remote_clipboard.lua` detects SSH, tmux, and Herdr contexts and uses OSC52/Wayland as appropriate. Personal `lua/brenocrs/set.lua` configures local `wl-copy`/`wl-paste`. Adapting the stock context detection would improve remote/tmux copy while retaining the existing local behavior.
2. **Transparency policy — already covered.** Stock `/etc/skel/.config/nvim/plugin/after/transparency.lua` clears selected highlight backgrounds. Personal Neo-tree and Lualine config already explicitly manage transparent highlight groups; borrow only additional groups if a concrete UI surface remains opaque.
3. **Theme reload — already covered through a better fit.** Stock `lua/plugins/omarchy-theme-hotreload.lua` listens for LazyVim’s `User LazyReload` event and reapplies transparency/theme state. The personal config is not LazyVim; its Omarchy staged palette adapter and single theme-set hook are the compatible path. Do not run a second watcher/reload mechanism.
4. **Neo-tree — present in both.** Stock enables the LazyVim Neo-tree extra. Personal config already declares and configures Neo-tree, alongside Oil and Grapple. Keep the personal setup and avoid adding another file navigator.
5. **Defaults — little to gain.** Stock sets `relativenumber=false` and `vim.g.autoformat=false`; the personal options make the same choices. Stock’s LazyVim extras are optional modules, not hidden Omarchy-only editing features. Add one only for a specific language/editor need.

## Bar appearance and theme precedence

The deployed `/home/pontual/.config/omarchy/shell.json` selects the stock `omarchy.bar`, keeps `bar.transparent=true`, and places the user `pontual.workspaces` clone and `sys-monitor` widget in the left section. The workspace widget itself painted an opaque rounded group using `Color.bar.background`; that made the transparency rail appear as one dark floating island. The system-monitor widget had no matching surface, so its content visually floated separately. The selected bar is not the installed-but-unselected `pontual.bar` alternative.

Theme and layout have different jobs. Omarchy’s theme templates/overlays can change theme tokens and generated shell values. In contrast, the active user `shell.json` chooses bar ID, widget placement, and the transparent setting; a theme change does not replace that layout. The user’s `shell.toml.tpl` is generated theme output, while `shell.json` remains the layout source. The widget surfaces use the current `Color.bar.background` theme token with a single subtle item opacity, so later themes recolor them without changing layout or making the full bar opaque.

### Deployed tint

Both authored QML files use the theme color `Color.bar.background` and set one surface opacity of `0.10`:

- `env/.config/omarchy/plugins/pontual.workspaces/BarWidget.qml`: the workspace group rectangle uses the theme color and `opacity: root.surfaceTintOpacity`.
- `env/.config/omarchy/plugins/sys-monitor/BarWidget.qml`: a rounded `Rectangle` behind the existing `WidgetButton` uses the same color and opacity with `Style.space(8)` radius. Normal monitor glyphs use the same bar foreground as metric text.

The tint and integration edits were deployed with complete backup at `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T031851.691107655Z` (`scope=apply`, host `omarchy-workstation`). All eight live paths match `env/`; `scripts/envctl diff --host omarchy-workstation` reports `0 path(s) differ`. Plugin hot reload did not update the visible workspace appearance, so the authorized `omarchy restart shell` was run once. Bar-only crops from both monitors afterward show wallpaper texture through the workspace surface with a slight theme tint; monitor glyphs match their text. This confirms the rendered result. The restart resolved the stale appearance, but the underlying Quickshell caching mechanism is unproven.

## Targeted plugin and menu repairs

The earlier `Hyprland is not defined` and duplicate `sys-monitor` IPC registration warnings predated the tint. The deployed search QML imports `Quickshell.Hyprland` and guards focused-monitor lookup; sys-monitor no longer creates a global `IpcHandler` per widget instance, while callers use Omarchy's shell toggle route. After the shell restart, the targeted Quickshell log query showed neither warning nor plugin error. It did show a Qt portal app-ID registration warning, which is outside these changes.

The same deployment restores the conditional stock `omarchy.system-update` widget, exposes OCR through `omarchy-capture-text`, routes notification history to the Foamy archive, and makes Quick Settings a submenu of native audio/network/Bluetooth/display/sys-monitor/nightlight panel routes.

## Evidence scope

The comparison used installed Omarchy defaults under `/usr/share/omarchy/default/bash` and `/etc/skel/.config/nvim`, the deployed Zsh and canonical personal Neovim tree at `env/.config/nvim`, active `shell.json` and QML, focused runtime logs, live-vs-env byte comparisons, `envctl diff`, and bar-only crops from both monitors. PontuArch's retained Neovim copy is not treated as the deployed source. See the PontuArch plugin review for its separate ecosystem shortlist.
