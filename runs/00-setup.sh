#!/usr/bin/env bash

set -e

CONFIG_FILE=".machine.conf"

echo "=== Machine Setup ==="
echo ""

# Detect if laptop (has battery)
if [ -d /sys/class/power_supply/BAT* ]; then
    DEFAULT_TYPE="laptop"
else
    DEFAULT_TYPE="desktop"
fi

read -p "Is this a laptop or desktop? [$DEFAULT_TYPE]: " MACHINE_TYPE
MACHINE_TYPE=${MACHINE_TYPE:-$DEFAULT_TYPE}

if [[ "$MACHINE_TYPE" == "desktop" ]]; then
    echo ""
    echo "Detecting connected monitors..."
    if command -v hyprctl &> /dev/null; then
        hyprctl monitors
    fi
    echo ""
    read -p "Enter primary monitor name (e.g., DP-3): " MONITOR_PRIMARY
    read -p "Enter secondary monitor name (e.g., HDMI-A-1) [leave empty for single monitor]: " MONITOR_SECONDARY
else
    MONITOR_PRIMARY="eDP-1"
    MONITOR_SECONDARY=""
fi

# Save config
cat > "$CONFIG_FILE" << CONFIG
MACHINE_TYPE=$MACHINE_TYPE
MONITOR_PRIMARY=$MONITOR_PRIMARY
MONITOR_SECONDARY=$MONITOR_SECONDARY
CONFIG

echo ""
echo "Configuration saved to $CONFIG_FILE:"
cat "$CONFIG_FILE"
echo ""
