#!/usr/bin/env bash

# Kanata Manager - Simple daemon: auto-stops kanata when Sofle is connected
# When Sofle detected: kanata OFF, show DEV
# When no Sofle: kanata ON (user can toggle with Alt+I)

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
KANATA_BIN=$(which kanata) || { notify-send "Kanata" "Binary not found in PATH"; exit 1; }
KANATA_CONFIG="$CONFIG_DIR/kanata/kanata.kbd"
STATE_FILE="/tmp/kanata-state"

# Check if Sofle is connected
is_sofle_connected() {
    hyprctl devices 2>/dev/null | grep -qi "josefadamcik-sofle"
}

# Check if kanata is running
is_kanata_running() {
    pgrep -x kanata >/dev/null 2>&1
}

# Main loop
while true; do
    if is_sofle_connected; then
        # Sofle connected - force kanata OFF
        is_kanata_running && pkill -x kanata 2>/dev/null
        echo "dev" > "$STATE_FILE"
    else
        # No Sofle - kanata should be ON (unless user toggled off)
        # If state file says "off", user manually stopped it
        if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "off" ]; then
            : # User manually disabled kanata, respect that
        else
            # Auto-start kanata if not running
            if ! is_kanata_running && [ -f "$KANATA_CONFIG" ]; then
                "$KANATA_BIN" -c "$KANATA_CONFIG" &
                echo "kanata" > "$STATE_FILE"
            fi
        fi
    fi
    
    pkill -RTMIN+8 waybar 2>/dev/null
    sleep 2
done
