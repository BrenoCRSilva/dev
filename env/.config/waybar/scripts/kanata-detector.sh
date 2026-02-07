#!/usr/bin/env bash

# Kanata Detector - Checks if Sofle keyboard is connected
# Returns: 0 if Sofle detected, 1 if not

SOFLE_PATTERNS="josefadamcik-sofle"

# Check hyprctl devices for Sofle keyboard
devices_output=$(hyprctl devices 2>/dev/null)

if echo "$devices_output" | grep -qi "$SOFLE_PATTERNS"; then
    exit 0  # Sofle detected
else
    exit 1  # Sofle not detected
fi
