#!/usr/bin/env bash

# Simple keyboard layout watcher (polling-based)
# Updates layout file when keyboard layout changes

LAYOUT_FILE="/tmp/kb-current-layout"
PREV_LAYOUT=""

# Function to get current layout
get_layout() {
    local layout_info=$(hyprctl devices 2>/dev/null | grep -A10 "josefadamcik-sofle" | grep "active keymap" | head -1)
    if echo "$layout_info" | grep -qi "portuguese\|br"; then
        echo "BR"
    else
        echo "US"
    fi
}

# Main loop - check every 500ms
while true; do
    CURRENT_LAYOUT=$(get_layout)
    
    if [ "$CURRENT_LAYOUT" != "$PREV_LAYOUT" ]; then
        echo "$CURRENT_LAYOUT" > "$LAYOUT_FILE"
        PREV_LAYOUT="$CURRENT_LAYOUT"
    fi
    
    sleep 0.5
done
