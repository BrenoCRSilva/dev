#!/usr/bin/env bash
#
# Cycle monitor modes: internal → extended → external only → internal
# Bind to a key in hyprland.conf for quick switching
#
ENV_LOCAL="$HOME/.env.local"
# shellcheck source=/dev/null
source "$ENV_LOCAL" || { notify-send "Display Error" "Missing ~/.env.local — run 00-setup.sh"; exit 1; }

INTERNAL="${MONITOR_PRIMARY:-eDP-1}"
EXTERNAL="${MONITOR_SECONDARY:-}"

# If secondary not set in env, try to detect live
if [[ -z "$EXTERNAL" ]]; then
    EXTERNAL="$(hyprctl monitors -j | jq -r --arg p "$INTERNAL" \
        '[.[] | select(.name != $p)] | first | .name // ""')"
fi

STATE_FILE="/tmp/monitor-mode"
current_mode="$(cat "$STATE_FILE" 2>/dev/null || echo "internal")"

restart_waybar() { killall waybar 2>/dev/null; sleep 0.5; waybar & }

apply_internal_only() {
    hyprctl keyword monitor "$INTERNAL,preferred,auto,1"
    [[ -n "$EXTERNAL" ]] && hyprctl keyword monitor "$EXTERNAL,disable"
    notify-send "Monitor Mode" "Internal only ($INTERNAL)"
    echo "internal" > "$STATE_FILE"
    restart_waybar
}

apply_external_only() {
    if [[ -z "$EXTERNAL" ]]; then
        notify-send "Monitor Mode" "No external monitor detected"
        return
    fi
    hyprctl keyword monitor "$INTERNAL,disable"
    hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
    for i in {1..10}; do hyprctl keyword workspace "$i,monitor:$EXTERNAL"; done
    notify-send "Monitor Mode" "External only ($EXTERNAL)"
    echo "external_only" > "$STATE_FILE"
    restart_waybar
}

apply_extended() {
    hyprctl keyword monitor "$INTERNAL,preferred,0x0,1"
    if [[ -z "$EXTERNAL" ]]; then
        notify-send "Monitor Mode" "No external monitor detected"
        return
    fi
    hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
    for i in {1..5};  do hyprctl keyword workspace "$i,monitor:$INTERNAL"; done
    for i in {6..10}; do hyprctl keyword workspace "$i,monitor:$EXTERNAL"; done
    notify-send "Monitor Mode" "Extended: $INTERNAL + $EXTERNAL"
    echo "extended" > "$STATE_FILE"
    restart_waybar
}

case "$current_mode" in
    "internal")
        if [[ -n "$EXTERNAL" ]]; then apply_extended
        else notify-send "Monitor Mode" "No external monitor detected"; fi
        ;;
    "extended")
        if [[ -n "$EXTERNAL" ]]; then apply_external_only
        else apply_internal_only; fi
        ;;
    "external_only"|*)
        apply_internal_only ;;
esac
