#!/usr/bin/env sh

# Handle lid switch events for laptop
# This script checks if external monitor is connected and handles monitor state accordingly

MONITORS=$(hyprctl monitors | grep -c "Monitor")

if [ "$MONITORS" -gt 1 ]; then
    # External monitor connected - disable internal display
    hyprctl keyword monitor "eDP-1, disable"
else
    # No external monitor - enable internal display
    hyprctl keyword monitor "eDP-1, enable"
fi