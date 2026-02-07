#!/usr/bin/env bash

# Hyprland Keyboard Monitor Daemon
# Detects keyboard layout changes in real-time and updates waybar

STATE_FILE="/tmp/kb-layer-state"
LAYOUT_FILE="/tmp/kb-current-layout"
SOCKET="/run/user/$(id - u)/hypr/$(ls -t /run/user/$(id - u)/hypr/ | head -1)/.socket2.sock"

# Initialize files
[ ! -f "$STATE_FILE" ] && echo "0" > "$STATE_FILE"
echo "US" > "$LAYOUT_FILE"

# Function to get current layout
get_layout() {
    local layout_info=$(hyprctl devices | grep -A10 "josefadamcik-sofle" | grep "active keymap" | head -1)
    if echo "$layout_info" | grep -qi "portuguese\|br"; then
        echo "BR"
    else
        echo "US"
    fi
}

# Function to update layout file
update_layout() {
    local current_layout=$(get_layout)
    local prev_layout=$(cat "$LAYOUT_FILE" 2>/dev/null || echo "US")
    
    if [ "$current_layout" != "$prev_layout" ]; then
        echo "$current_layout" > "$LAYOUT_FILE"
        # Signal waybar to refresh (optional - waybar has interval anyway)
    fi
}

# Check socket exists
if [ ! -S "$SOCKET" ]; then
    echo "Hyprland socket not found at $SOCKET"
    exit 1
fi

# Listen for keyboard events via socat
socat -u UNIX-CONNECT:"$SOCKET" - 2>/dev/null | while read -r line; do
    # Check for keyboard-related events
    if echo "$line" | grep -q "activelayout"; then
        update_layout
    fi
done
