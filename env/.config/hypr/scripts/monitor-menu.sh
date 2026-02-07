#!/bin/bash

# Wofi-based monitor configuration menu
# Similar to Windows+P but with visual menu

choice=$(echo -e "Internal Only\nExternal Only\nExtended (Side by Side)\nMirror Displays\nCancel" | wofi --dmenu --prompt "Display Mode" --conf "$HOME/.config/wofi/wpp-config")

INTERNAL="eDP-1"
EXTERNAL=$(hyprctl monitors | grep "Monitor" | grep -v "$INTERNAL" | head -1 | awk '{print $2}')

case "$choice" in
    "Internal Only")
        hyprctl keyword monitor "$INTERNAL,preferred,auto,1"
        [ -n "$EXTERNAL" ] && hyprctl keyword monitor "$EXTERNAL,disable"
        notify-send "Display Mode" "Internal display only"
        echo "internal" > /tmp/monitor-mode
        ;;
    "External Only")
        if [ -n "$EXTERNAL" ]; then
            hyprctl keyword monitor "$INTERNAL,disable"
            hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
            notify-send "Display Mode" "External display only"
            echo "external_only" > /tmp/monitor-mode
        else
            notify-send "Display Mode" "No external monitor detected!"
        fi
        ;;
    "Extended (Side by Side)")
        if [ -n "$EXTERNAL" ]; then
            hyprctl keyword monitor "$INTERNAL,preferred,0x0,1"
            hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
            notify-send "Display Mode" "Extended: Internal + External"
            echo "extended" > /tmp/monitor-mode
        else
            notify-send "Display Mode" "No external monitor detected!"
        fi
        ;;
    "Mirror Displays")
        if [ -n "$EXTERNAL" ]; then
            hyprctl keyword monitor "$INTERNAL,preferred,auto,1"
            hyprctl keyword monitor "$EXTERNAL,preferred,auto,1,mirror,$INTERNAL"
            notify-send "Display Mode" "Mirrored displays"
            echo "mirror" > /tmp/monitor-mode
        else
            notify-send "Display Mode" "No external monitor detected!"
        fi
        ;;
esac

# Restart waybar to adjust for new monitor layout
killall waybar 2>/dev/null
sleep 0.5
waybar &
