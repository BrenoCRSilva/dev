#!/bin/bash

# Monitor configuration script - similar to Windows+P
# Cycles through: Internal → External → Extended → Internal Only

STATE_FILE="/tmp/monitor-mode"
MONITOR_INTERNAL="eDP-1"

# Detect external monitors (excluding internal)
get_external_monitor() {
    hyprctl monitors | grep "Monitor" | grep -v "$MONITOR_INTERNAL" | head -1 | awk '{print $2}'
}

EXTERNAL=$(get_external_monitor)

# Read current mode
current_mode=$(cat "$STATE_FILE" 2>/dev/null || echo "internal")

cycle_mode() {
    case "$current_mode" in
        "internal")
            if [ -n "$EXTERNAL" ]; then
                echo "extended" > "$STATE_FILE"
                apply_extended
            else
                notify-send "Monitor Mode" "No external monitor detected"
                echo "internal" > "$STATE_FILE"
            fi
            ;;
        "extended")
            if [ -n "$EXTERNAL" ]; then
                echo "external_only" > "$STATE_FILE"
                apply_external_only
            else
                echo "internal" > "$STATE_FILE"
                apply_internal_only
            fi
            ;;
        "external_only")
            echo "internal" > "$STATE_FILE"
            apply_internal_only
            ;;
        *)
            echo "internal" > "$STATE_FILE"
            apply_internal_only
            ;;
    esac
}

apply_internal_only() {
    hyprctl keyword monitor "$MONITOR_INTERNAL,preferred,auto,1"
    if [ -n "$EXTERNAL" ]; then
        hyprctl keyword monitor "$EXTERNAL,disable"
    fi
    
    # Reset workspaces to single monitor
    for i in 1 2 3 4 5 6 7 8 9 10; do
        hyprctl keyword workspace "$i"
    done
    
    notify-send "Monitor Mode" "Internal display only"
    
    # Restart waybar for single monitor
    killall waybar 2>/dev/null
    waybar &
}

apply_external_only() {
    hyprctl keyword monitor "$MONITOR_INTERNAL,disable"
    if [ -n "$EXTERNAL" ]; then
        hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
        
        # Move all workspaces to external
        for i in 1 2 3 4 5 6 7 8 9 10; do
            hyprctl keyword workspace "$i,monitor:$EXTERNAL"
        done
        
        notify-send "Monitor Mode" "External display only"
    fi
    
    # Restart waybar
    killall waybar 2>/dev/null
    waybar &
}

apply_extended() {
    # Enable internal at 0,0
    hyprctl keyword monitor "$MONITOR_INTERNAL,preferred,0x0,1"
    
    # Enable external to the right
    if [ -n "$EXTERNAL" ]; then
        hyprctl keyword monitor "$EXTERNAL,preferred,auto,1"
        
        # Workspaces 1-5 on internal, 6-10 on external
        for i in 1 2 3 4 5; do
            hyprctl keyword workspace "$i,monitor:$MONITOR_INTERNAL"
        done
        for i in 6 7 8 9 10; do
            hyprctl keyword workspace "$i,monitor:$EXTERNAL"
        done
        
        notify-send "Monitor Mode" "Extended display (Internal + External)"
    fi
    
    # Restart waybar
    killall waybar 2>/dev/null
    waybar &
}

# Execute
cycle_mode
