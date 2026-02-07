#!/usr/bin/env bash

# Get the main keyboard device name (excluding power/sleep buttons)
keyboard=$(hyprctl devices | grep -A3 "Keyboard at" | grep -v "power\|sleep" | grep "Keyboard at" | head -1 | sed 's/.*at \(.*\):/\1/')

if [ -z "$keyboard" ]; then
    # Fallback to first keyboard if no main found
    keyboard=$(hyprctl devices | grep "Keyboard at" | head -1 | sed 's/.*at \(.*\):/\1/')
fi

# Get current layout index and keymap
layout_info=$(hyprctl devices | grep -A10 "$keyboard" | grep "active keymap")
layout=$(echo "$layout_info" | sed 's/.*active keymap: //')

# Get layout code
if echo "$layout" | grep -qi "portuguese\|br"; then
    echo "BR"
else
    echo "US"
fi
