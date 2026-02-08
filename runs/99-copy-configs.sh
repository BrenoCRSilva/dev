#!/usr/bin/env bash
#
# Copy machine-specific configuration files
# Phase: copy-configs - Machine-specific config deployment
#

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

print_header "Machine-Specific Configuration"

# Verify .machine.conf exists
if [[ ! -f .machine.conf ]]; then
    log_error ".machine.conf not found. Run 00-setup.sh first"
    exit 1
fi

# shellcheck source=/dev/null
source .machine.conf

CONFIG_DIR="$HOME/.config"

if [[ "$MACHINE_TYPE" == "laptop" ]]; then
    log_info "Using laptop configs..."
    execute cp "$CONFIG_DIR/hypr/hyprland-laptop.conf" "$CONFIG_DIR/hypr/hyprland.conf"
    execute cp "$CONFIG_DIR/hypr/hypridle-laptop.conf" "$CONFIG_DIR/hypr/hypridle.conf"
    execute cp "$CONFIG_DIR/waybar/config-laptop.jsonc" "$CONFIG_DIR/waybar/config.jsonc"
else
    log_info "Using desktop configs..."
    execute cp "$CONFIG_DIR/hypr/hyprland-desktop.conf" "$CONFIG_DIR/hypr/hyprland.conf"
    execute cp "$CONFIG_DIR/hypr/hypridle-desktop.conf" "$CONFIG_DIR/hypr/hypridle.conf"
    execute cp "$CONFIG_DIR/waybar/config-desktop.jsonc" "$CONFIG_DIR/waybar/config.jsonc"
fi

log_success "Configs copied for $MACHINE_TYPE"

print_footer "Machine-specific configuration complete"
