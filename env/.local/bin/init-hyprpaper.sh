#!/bin/bash

# Initialize Hyprpaper wallpaper on startup

WALLPAPER_DIR="$HOME/.config/wallpapers"
DEFAULT_WALLPAPER="$WALLPAPER_DIR/chinatown.png"

if [ ! -f "$DEFAULT_WALLPAPER" ]; then
    echo "Warning: Default wallpaper not found: $DEFAULT_WALLPAPER"
    # Try to find any wallpaper
    WALLPAPER=$(ls "$WALLPAPER_DIR"/*.{jpg,png,jpeg} 2>/dev/null | head -1)
    if [ -z "$WALLPAPER" ]; then
        echo "No wallpapers found, skipping"
        exit 0
    fi
else
    WALLPAPER="$DEFAULT_WALLPAPER"
fi

echo "Initializing Hyprpaper with wallpaper: $WALLPAPER"

# Unload any existing wallpapers
hyprctl hyprpaper unload all >/dev/null 2>&1

# Preload wallpaper
hyprctl hyprpaper preload "$WALLPAPER" >/dev/null 2>&1

# Apply to all monitors
hyprctl hyprpaper wallpaper "DP-3,$WALLPAPER" >/dev/null 2>&1
hyprctl hyprpaper wallpaper "$WALLPAPER" >/dev/null 2>&1

echo "Wallpaper initialized"