#!/usr/bin/env bash
STATE_FILE="/tmp/vial-layer-state"

# Read current layer (default 0)
if [ -f "$STATE_FILE" ]; then
    CURRENT=$(cat "$STATE_FILE")
else
    CURRENT=0
fi

# Cycle through layers: 0 -> 1 -> 2 -> 3 -> 0
NEXT=$(( ($CURRENT + 1) % 4 ))
echo $NEXT > "$STATE_FILE"