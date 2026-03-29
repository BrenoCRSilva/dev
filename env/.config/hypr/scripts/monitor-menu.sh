#!/usr/bin/env bash
#
# Wofi-based monitor configuration menu (Windows+P style)
#
ENV_LOCAL="$HOME/.env.local"
# shellcheck source=/dev/null
source "$ENV_LOCAL" || { notify-send "Display Error" "Missing ~/.env.local — run 00-setup.sh"; exit 1; }

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
INTERNAL="${MONITOR_PRIMARY:-eDP-1}"
EXTERNAL="${MONITOR_SECONDARY:-}"

# If secondary not set in env, try to detect live
if [[ -z "$EXTERNAL" ]]; then
    EXTERNAL="$(hyprctl monitors -j | jq -r --arg p "$INTERNAL" \
        '[.[] | select(.name != $p)] | first | .name // ""')"
fi

restart_waybar() { killall waybar 2>/dev/null; sleep 0.5; waybar & }

choice=$(printf "Internal Only\nExternal Only\nExtended (Side by Side)\nMirror Displays\nCancel" \
    | wofi --dmenu --prompt "Display Mode" --conf "$CONFIG_DIR/wofi/wpp-config")

case "$choice" in
    "Internal Only")
        hyprctl keyword monitor "$INTERNAL,preferred,auto,1"
        [[ -n "$EXTERNAL" ]] && hyprctl keyword monitor "$EXTERNAL,disable"
        notify-send "Display Mode" "Internal only ($INTERNAL)"
        echo "internal" > /tmp/monitor-mode
        restart_waybar
        ;;
    "External Only")
        if [[ -n "$EXTERNAL" ]]; then
            hyprctl keyword monitor "$INTERNAL,disable"
            hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
            notify-send "Display Mode" "External only ($EXTERNAL)"
            echo "external_only" > /tmp/monitor-mode
            restart_waybar
        else
            notify-send "Display Mode" "No external monitor detected!"
        fi
        ;;
    "Extended (Side by Side)")
        if [[ -n "$EXTERNAL" ]]; then
            hyprctl keyword monitor "$INTERNAL,preferred,0x0,1"
            hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
            notify-send "Display Mode" "Extended: $INTERNAL + $EXTERNAL"
            echo "extended" > /tmp/monitor-mode
            restart_waybar
        else
            notify-send "Display Mode" "No external monitor detected!"
        fi
        ;;
    "Mirror Displays")
        if [[ -n "$EXTERNAL" ]]; then
            hyprctl keyword monitor "$INTERNAL,preferred,auto,1"
            hyprctl keyword monitor "$EXTERNAL,preferred,auto,1,mirror,$INTERNAL"
            notify-send "Display Mode" "Mirrored: $EXTERNAL → $INTERNAL"
            echo "mirror" > /tmp/monitor-mode
            restart_waybar
        else
            notify-send "Display Mode" "No external monitor detected!"
        fi
        ;;
    "Cancel"|"") exit 0 ;;
esac
