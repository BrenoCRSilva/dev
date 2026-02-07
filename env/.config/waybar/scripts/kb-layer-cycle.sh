#!/usr/bin/env bash

STATE_FILE="/tmp/kb-layer-state"

# Read current layer (default 0)
if [ -f "$STATE_FILE" ]; then
    CURRENT=$(cat "$STATE_FILE")
else
    CURRENT=0
fi

# Cycle through layers: 0 -> 1 -> 2 -> 3 -> 0
NEXT=$(( ($CURRENT + 1) % 4 ))
echo $NEXT > "$STATE_FILE"

# Show notification with new layer
case "$NEXT" in
    0) notify-send "Keyboard Layer" "Base Layer" ;;
    1) notify-send "Keyboard Layer" "Navigation Layer" ;;
    2) notify-send "Keyboard Layer" "Symbols Layer" ;;
    3) notify-send "Keyboard Layer" "Numbers Layer" ;;
esac

# Signal waybar to refresh the module (SIGRTMIN+8 = signal 8)
pkill -RTMIN+8 waybar 2>/dev/null || true
