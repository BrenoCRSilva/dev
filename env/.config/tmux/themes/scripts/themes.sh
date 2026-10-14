#!/usr/bin/env bash
# Colors come from Omarchy's staged palette. A small Tokyo Night fallback keeps
# the statusline usable on non-Omarchy hosts or before the first theme set.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PALETTE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/tmux-palette.sh"
if [[ -r "$PALETTE" ]]; then
  source "$PALETTE"
else
  declare -gA THEME=(
    [background]="#1a1b26" [foreground]="#c0caf5" [black]="#1a1b26"
    [blue]="#7aa2f7" [cyan]="#7dcfff" [green]="#9ece6a"
    [magenta]="#bb9af7" [red]="#f7768e" [white]="#a9b1d6"
    [yellow]="#e0af68" [bblack]="#24283b" [bblue]="#7aa2f7"
    [bcyan]="#7dcfff" [bgreen]="#9ece6a" [bmagenta]="#bb9af7"
    [bred]="#f7768e" [bwhite]="#c0caf5" [byellow]="#e0af68"
  )
fi

# Override background with "default" when the transparent option is enabled.
TRANSPARENT_THEME="$(tmux show-option -gv @tokyo-night-tmux_transparent 2>/dev/null)"
if [ "${TRANSPARENT_THEME}" == 1 ]; then
  THEME["background"]="default"
fi

# Static GitHub status colors (not theme-driven).
THEME['ghgreen']="#3fb950"
THEME['ghmagenta']="#A371F7"
THEME['ghred']="#d73a4a"
THEME['ghyellow']="#d29922"

RESET="#[fg=${THEME[foreground]},bg=${THEME[background]},nobold,noitalics,nounderscore,nodim]"
