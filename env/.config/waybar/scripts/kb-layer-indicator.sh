#!/usr/bin/env bash

STATE_FILE="/tmp/kb-layer-state"
LAYOUT_FILE="/tmp/kb-current-layout"

# Read current layer state
if [ -f "$STATE_FILE" ]; then
    CURRENT_LAYER=$(cat "$STATE_FILE")
    case "$CURRENT_LAYER" in
        0) LAYER_NAME="Base" ;;
        1) LAYER_NAME="Nav" ;;
        2) LAYER_NAME="Sym" ;;
        3) LAYER_NAME="Num" ;;
        *) LAYER_NAME="Base" ;;
    esac
else
    echo "0" > "$STATE_FILE"
    LAYER_NAME="Base"
fi

# Get current keyboard layout (check daemon file first, then query hyprctl)
if [ -f "$LAYOUT_FILE" ]; then
    layout=$(cat "$LAYOUT_FILE")
else
    # Fallback to querying directly
    layout_info=$(hyprctl devices | grep -A10 "josefadamcik-sofle" | grep "active keymap" | head -1)
    if echo "$layout_info" | grep -qi "portuguese\|br"; then
        layout="BR"
    else
        layout="US"
    fi
    echo "$layout" > "$LAYOUT_FILE"
fi

# Output combined: Layer | Layout
echo "$LAYER_NAME | $layout"
