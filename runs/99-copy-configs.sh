#!/usr/bin/env bash
#
# Copy machine-specific configuration files
# Phase: copy-configs - Machine-specific config deployment
#
# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "Machine-Specific Configuration"

load_machine_env

CONFIG_DIR="$HOME/.config"

# ─── Monitor line generation ──────────────────────────────────────────────────

build_monitor_lines() {
    if ! command_exists hyprctl || ! command_exists jq; then
        log_warning "hyprctl/jq not available — falling back to 'preferred,auto'"
        if [[ "$MACHINE_TYPE" == "laptop" ]]; then
            echo "monitor=$MONITOR_PRIMARY,preferred,auto,1"
            echo "monitor=,preferred,auto,1"
        else
            echo "monitor=$MONITOR_PRIMARY,preferred,auto,1"
            if [[ -n "$MONITOR_SECONDARY" ]]; then
                local transform_suffix=""
                if [[ -n "${MONITOR_SECONDARY_TRANSFORM:-}" && "$MONITOR_SECONDARY_TRANSFORM" != "0" ]]; then
                    transform_suffix=",transform,$MONITOR_SECONDARY_TRANSFORM"
                fi
                echo "monitor=$MONITOR_SECONDARY,preferred,auto,1${transform_suffix}"
            fi
        fi
        return
    fi

    local monitors_json
    monitors_json="$(hyprctl monitors -j 2>/dev/null)"

    local primary_res primary_x primary_y primary_scale
    local secondary_res secondary_x secondary_y secondary_scale

    primary_res="$(jq -r --arg m "$MONITOR_PRIMARY" \
        '.[] | select(.name == $m) | "\(.width)x\(.height)"' <<< "$monitors_json")"
    primary_scale="$(jq -r --arg m "$MONITOR_PRIMARY" \
        '.[] | select(.name == $m) | .scale' <<< "$monitors_json")"
    primary_x="$(jq -r --arg m "$MONITOR_PRIMARY" \
        '.[] | select(.name == $m) | .x' <<< "$monitors_json")"
    primary_y="$(jq -r --arg m "$MONITOR_PRIMARY" \
        '.[] | select(.name == $m) | .y' <<< "$monitors_json")"

    primary_res="${primary_res:-preferred}"
    primary_scale="${primary_scale:-1}"
    primary_x="${primary_x:-0}"
    primary_y="${primary_y:-0}"

    if [[ "$MACHINE_TYPE" == "laptop" ]]; then
        echo "monitor=$MONITOR_PRIMARY,${primary_res},${primary_x}x${primary_y},${primary_scale}"
        echo "monitor=,preferred,auto,1"
        return
    fi

    if [[ -n "$MONITOR_SECONDARY" ]]; then
        secondary_res="$(jq -r --arg m "$MONITOR_SECONDARY" \
            '.[] | select(.name == $m) | "\(.width)x\(.height)"' <<< "$monitors_json")"
        secondary_scale="$(jq -r --arg m "$MONITOR_SECONDARY" \
            '.[] | select(.name == $m) | .scale' <<< "$monitors_json")"
        secondary_x="$(jq -r --arg m "$MONITOR_SECONDARY" \
            '.[] | select(.name == $m) | .x' <<< "$monitors_json")"
        secondary_y="$(jq -r --arg m "$MONITOR_SECONDARY" \
            '.[] | select(.name == $m) | .y' <<< "$monitors_json")"

        secondary_res="${secondary_res:-preferred}"
        secondary_scale="${secondary_scale:-1}"
        secondary_x="${secondary_x:-auto}"
        secondary_y="${secondary_y:-0}"
    fi

    echo "monitor=$MONITOR_PRIMARY,${primary_res},${primary_x}x${primary_y},${primary_scale}"

    if [[ -n "$MONITOR_SECONDARY" ]]; then
        local transform_suffix=""
        if [[ -n "${MONITOR_SECONDARY_TRANSFORM:-}" && "$MONITOR_SECONDARY_TRANSFORM" != "0" ]]; then
            transform_suffix=",transform,$MONITOR_SECONDARY_TRANSFORM"
        fi
        echo "monitor=$MONITOR_SECONDARY,${secondary_res},${secondary_x}x${secondary_y},${secondary_scale}${transform_suffix}"
    fi
}

# ─── Patch monitor section in a hyprland conf file ───────────────────────────

patch_monitor_lines() {
    local conf="$1"
    local monitor_lines
    monitor_lines="$(build_monitor_lines)"

    log_info "Patching monitor lines in $conf:"
    echo "$monitor_lines" | sed 's/^/    /'

    # Replace everything between ### MONITORS ### markers
    # Uses awk so it handles multi-line replacement cleanly
    local tmp
    tmp="$(mktemp)"
    awk -v lines="$monitor_lines" '
        /^################$/ && found == 0 { in_header = 1 }
        in_header && /^### MONITORS ###/ { in_monitors = 1; found = 1; print; next }
        in_monitors && /^################$/ { in_monitors = 0; print lines; print; next }
        in_monitors { next }
        { print }
    ' "$conf" > "$tmp" && mv "$tmp" "$conf"
}

# ─── Deploy configs ───────────────────────────────────────────────────────────

if [[ "$MACHINE_TYPE" == "laptop" ]]; then
    log_info "Deploying laptop configs..."
    execute cp "$CONFIG_DIR/hypr/hyprland-laptop.conf"   "$CONFIG_DIR/hypr/hyprland.conf"
    execute cp "$CONFIG_DIR/hypr/hypridle-laptop.conf"   "$CONFIG_DIR/hypr/hypridle.conf"
    execute cp "$CONFIG_DIR/hypr/hyprpaper-laptop.conf"  "$CONFIG_DIR/hypr/hyprpaper.conf"
    execute cp "$CONFIG_DIR/waybar/config-laptop.jsonc"  "$CONFIG_DIR/waybar/config.jsonc"
else
    log_info "Deploying desktop configs..."
    execute cp "$CONFIG_DIR/hypr/hyprland-desktop.conf"  "$CONFIG_DIR/hypr/hyprland.conf"
    execute cp "$CONFIG_DIR/hypr/hypridle-desktop.conf"  "$CONFIG_DIR/hypr/hypridle.conf"
    execute cp "$CONFIG_DIR/hypr/hyprpaper-desktop.conf" "$CONFIG_DIR/hypr/hyprpaper.conf"
    execute cp "$CONFIG_DIR/waybar/config-desktop.jsonc" "$CONFIG_DIR/waybar/config.jsonc"
fi

patch_monitor_lines "$CONFIG_DIR/hypr/hyprland.conf"

# Patch monitor names in hyprpaper.conf (still name-based, not position-based)
sed -i "s/MONITOR_PRIMARY/$MONITOR_PRIMARY/g"   "$CONFIG_DIR/hypr/hyprpaper.conf"
sed -i "s/MONITOR_SECONDARY/$MONITOR_SECONDARY/g" "$CONFIG_DIR/hypr/hyprpaper.conf"

log_success "Configs deployed for $MACHINE_TYPE"
print_footer "Machine-specific configuration complete"
