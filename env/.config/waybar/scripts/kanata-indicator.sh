#!/usr/bin/env bash

# Kanata Indicator - Simple output for waybar
# Shows: DEV (Sofle), 󰌒 (Kanata on), 󰌒 NAV (Kanata off)

STATE_FILE="/tmp/kanata-state"
LAYOUT_FILE="/tmp/kb-current-layout"

# Get layout
if [ -f "$LAYOUT_FILE" ]; then
    LAYOUT=$(cat "$LAYOUT_FILE")
else
    LAYOUT="US"
fi

# Get state (default to checking if kanata is running)
if [ -f "$STATE_FILE" ]; then
    STATE=$(cat "$STATE_FILE")
else
    if pgrep -x kanata >/dev/null 2>&1; then
        STATE="kanata"
    else
        STATE="off"
    fi
fi

# Output with sized spans
case "$STATE" in
    "dev")
        echo "{\"text\": \"<span size='18000'>󰌌</span> <span size='12000' rise='2000'>DEV | $LAYOUT</span>\", \"tooltip\": \"Sofle connected - hardware layers\", \"class\": \"kanata-dev\"}"
        ;;
    "kanata")
        echo "{\"text\": \"<span size='18000'>󰬒</span> <span size='12000' rise='2000'>DEV | $LAYOUT</span>\", \"tooltip\": \"Kanata active\", \"class\": \"kanata-on\"}"
        ;;
    "off")
        echo "{\"text\": \"<span size='18000'>󰬒</span> <span size='12000' rise='2000'>NAV | $LAYOUT</span>\", \"tooltip\": \"Kanata off\", \"class\": \"kanata-off\"}"
        ;;
    *)
        echo "{\"text\": \"<span size='18000'>󰌒</span> <span size='12000' rise='2000'>? | $LAYOUT</span>\", \"tooltip\": \"Unknown\", \"class\": \"kanata-off\"}"
        ;;
esac
