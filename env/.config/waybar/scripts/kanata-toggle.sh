#!/usr/bin/env bash

# Kanata Toggle - Toggle kanata on/off with Alt+I
# Only works when Sofle is NOT connected

STATE_FILE="/tmp/kanata-state"
KANATA_BIN="$HOME/.cargo/bin/kanata"
KANATA_CONFIG="$HOME/.config/kanata/kanata.kbd"

# Check if Sofle is connected
if hyprctl devices 2>/dev/null | grep -qi "josefadamcik-sofle"; then
    notify-send "Kanata" "Cannot toggle - Sofle keyboard connected"
    exit 0
fi

# Toggle kanata
if pgrep -x kanata >/dev/null 2>&1; then
    # Stop kanata
    pkill -x kanata 2>/dev/null
    echo "off" > "$STATE_FILE"
    notify-send "Kanata" "Stopped"
else
    # Start kanata
    if [ -f "$KANATA_CONFIG" ]; then
        "$KANATA_BIN" -c "$KANATA_CONFIG" &
        echo "kanata" > "$STATE_FILE"
        notify-send "Kanata" "Started"
    fi
fi

pkill -RTMIN+8 waybar 2>/dev/null
