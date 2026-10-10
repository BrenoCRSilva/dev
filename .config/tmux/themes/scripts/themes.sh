#!/usr/bin/env bash
# Colors come from the active PontuArch theme. The daemon regenerates
# pontuarch-colors.sh (the THEME associative array) on every theme switch; this
# file only sources it and layers the non-theme bits (transparency, the static
# GitHub status colors, RESET) on top — preserving the original statusline look.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generated palette. Falls back to the shipped default if the daemon hasn't run.
source "$CURRENT_DIR/pontuarch-colors.sh"

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
