#!/bin/bash
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
wallpaper_dir="$CONFIG_DIR/wallpapers"

choice=$({
    ls "$wallpaper_dir"/*.{jpg,png,jpeg} 2>/dev/null | xargs -n1 basename
    echo "Exit"
} | wofi --dmenu --conf "$CONFIG_DIR/wofi/wpp-config" --prompt "Select Wallpaper")

case $choice in
    "Exit")
        exit 0
        ;;
    *)
        imv "$wallpaper_dir/$choice" &
        imv_pid=$!
        
        confirm=$(echo -e "Apply\nBack" | wofi --dmenu --conf "$CONFIG_DIR/wofi/confirm-config" --prompt "Apply this wallpaper?")
        
        kill $imv_pid 2>/dev/null
        
        case $confirm in
            "Apply")
                echo "Applying wallpaper: $choice"
                wallpaper_path="$wallpaper_dir/$choice"
                
                # Start hyprpaper if not running
                if ! pgrep -x hyprpaper > /dev/null; then
                    hyprctl dispatch exec hyprpaper
                    sleep 1
                fi
                
                # Unload all existing wallpapers
                hyprctl hyprpaper unload all 2>/dev/null
                
                # Preload the new wallpaper
                hyprctl hyprpaper preload "$wallpaper_path" 2>/dev/null
                
                # Apply to all connected monitors dynamically
                hyprctl monitors | grep "^Monitor" | awk '{print $2}' | while read -r monitor; do
                    hyprctl hyprpaper wallpaper "$monitor,$wallpaper_path" 2>/dev/null
                done
                
                # Show success notification
                notify-send "Wallpaper Applied" "$choice" 2>/dev/null
                ;;
            "Back")
                echo "Going back to wallpaper selection..."
                exec "$0"
                ;;
        esac
        ;;
esac
