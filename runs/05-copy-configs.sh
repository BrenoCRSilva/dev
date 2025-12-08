#!/usr/bin/env bash

set -e

echo "Copying machine-specific configs..."

if [ ! -f .machine.conf ]; then
    echo "ERROR: .machine.conf not found. Run 00-setup.sh first"
    exit 1
fi

source .machine.conf

CONFIG_DIR="$HOME/.config"

if [ "$MACHINE_TYPE" = "laptop" ]; then
    echo "Using laptop configs..."
    cp "$CONFIG_DIR/hypr/hyprland-laptop.conf" "$CONFIG_DIR/hypr/hyprland.conf"
    cp "$CONFIG_DIR/hypr/hypridle-laptop.conf" "$CONFIG_DIR/hypr/hypridle.conf"
    cp "$CONFIG_DIR/waybar/config-laptop" "$CONFIG_DIR/waybar/config"
else
    echo "Using desktop configs..."
    cp "$CONFIG_DIR/hypr/hyprland-desktop.conf" "$CONFIG_DIR/hypr/hyprland.conf"
    cp "$CONFIG_DIR/hypr/hypridle-desktop.conf" "$CONFIG_DIR/hypr/hypridle.conf"
    cp "$CONFIG_DIR/waybar/config-desktop" "$CONFIG_DIR/waybar/config"
fi

echo "✓ Configs copied for $MACHINE_TYPE"
