#!/bin/bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
choice=$(echo -e "⏻  Power Options\n󰸉  Wallpapers\n  File Manager\n󰩈  Exit" | wofi --dmenu --prompt "Main Menu" --conf "$CONFIG_DIR/wofi/menu-config")

case $choice in
    "⏻  Power Options")
        "$script_dir/power-menu.sh"
        ;;
    "󰸉  Wallpapers")
        "$script_dir/wallpaper-menu.sh"
        ;;
    "  File Manager")
        nohup thunar / & 
        disown
        ;;
esac
