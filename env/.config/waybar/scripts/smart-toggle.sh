#!/usr/bin/env bash

# Smart Alt+I toggle - Context-aware keybinding
# Sofle connected: Toggle language (US/BR)
# No Sofle: Toggle kanata

STATE_FILE="/tmp/kanata-state"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
KANATA_BIN="$HOME/.cargo/bin/kanata"
KANATA_CONFIG="$CONFIG_DIR/kanata/kanata.kbd"

# Check if Sofle is connected
if hyprctl devices 2>/dev/null | grep -qi "josefadamcik-sofle"; then
    # Sofle connected - toggle language
    hyprctl switchxkblayout all next
    # The kb-layout-watcher will detect this and update waybar
else
    # No Sofle - toggle kanata
    if pgrep -x kanata >/dev/null 2>&1; then
        pkill -x kanata 2>/dev/null
        echo "off" > "$STATE_FILE"
        notify-send "Kanata" "Stopped"
    else
        if [ -f "$KANATA_CONFIG" ]; then
            "$KANATA_BIN" -c "$KANATA_CONFIG" &
            echo "kanata" > "$STATE_FILE"
            notify-send "Kanata" "Started"
        fi
    fi
fi

pkill -RTMIN+8 waybar 2>/dev/null
