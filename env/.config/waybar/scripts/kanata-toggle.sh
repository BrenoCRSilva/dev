#!/usr/bin/env bash
# Kanata Toggle - Toggle kanata on/off with Alt+I
# Only works when Sofle is NOT connected

STATE_FILE="/tmp/kanata-state"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
KANATA_BIN=$(which kanata) || { notify-send "Kanata" "Binary not found in PATH"; exit 1; }
KANATA_CONFIG="$CONFIG_DIR/kanata/kanata.kbd"

# Check if Sofle is connected
if hyprctl devices 2>/dev/null | grep -qi "josefadamcik-sofle"; then
    notify-send "Kanata" "Cannot toggle - Sofle keyboard connected"
    exit 0
fi

# Toggle kanata
if pgrep -x kanata >/dev/null 2>&1 || sudo pgrep -x kanata >/dev/null 2>&1; then
    # Stop kanata
    pkill -x kanata 2>/dev/null || sudo pkill -x kanata 2>/dev/null
    echo "off" > "$STATE_FILE"
    notify-send "Kanata" "Stopped"
else
    # Start kanata
    if [ -f "$KANATA_CONFIG" ]; then
        "$KANATA_BIN" -c "$KANATA_CONFIG" &
        echo "kanata" > "$STATE_FILE"
        notify-send "Kanata" "Started"
    else
        notify-send "Kanata" "Config not found: $KANATA_CONFIG"
    fi
fi

pkill -RTMIN+8 waybar 2>/dev/null
