#!/usr/bin/env bash
# ANSI names resolve through the terminal palette generated from Omarchy's
# active theme. This mirrors Omarchy's own tmux theme convention.
declare -gA THEME=(
  [background]=default [foreground]=default [black]=black
  [blue]=blue [cyan]=cyan [green]=green [magenta]=magenta [red]=red
  [white]=white [yellow]=yellow [bblack]=brightblack [bblue]=brightblue
  [bcyan]=brightcyan [bgreen]=brightgreen [bmagenta]=brightmagenta
  [bred]=brightred [bwhite]=brightwhite [byellow]=brightyellow
)

RESET="#[fg=${THEME[foreground]},bg=${THEME[background]},nobold,noitalics,nounderscore,nodim]"
