#!/usr/bin/env bash
STATE_FILE="/tmp/vial-layer-state"
LAYER_NAME="Base"

# Read current state
if [ -f "$STATE_FILE" ]; then
    CURRENT_LAYER=$(cat "$STATE_FILE")
    case "$CURRENT_LAYER" in
        0) LAYER_NAME="Base (0)" ;;
        1) LAYER_NAME="Navigation (1)" ;;
        2) LAYER_NAME="Symbols (2)" ;;
        3) LAYER_NAME="Numbers (3)" ;;
        *) LAYER_NAME="Unknown" ;;
    esac
else
    echo "0" > "$STATE_FILE"
fi

echo "$LAYER_NAME"