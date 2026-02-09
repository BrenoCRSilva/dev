#!/usr/bin/env bash

# Define the options
options="⏻  Shutdown\n󰑙  Reboot\n󰍃  Logout\n󰒲  Sleep\n󰌾  Lock\n󰩈  Exit"
# Show wofi menu and get selection
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
selected=$(echo -e "$options" | wofi --dmenu --conf "$CONFIG_DIR/wofi/menu-config")
# Execute based on selection
case $selected in
    "⏻  Shutdown")
        systemctl poweroff
        ;;
    "󰑙  Reboot")
        systemctl reboot
        ;;
    "󰍃  Logout")
        hyprctl dispatch exit
        ;;
    "󰒲  Sleep")
        hybrctl dispatch dpms off
        ;;
    "󰌾  Lock")
        hyprlock 
        ;;
    "󰩈  Exit")
        ;;
esac
