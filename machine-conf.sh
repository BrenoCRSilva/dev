#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="$script_dir/.machine.conf"

usage() {
    cat <<'EOF'
Usage: ./machine-conf.sh [options]

Create or update the .machine.conf file that drives machine-specific configs.

Options:
  --type <laptop|desktop>    Set the machine type without prompting
  --primary <name>           Set the primary monitor name (desktop only)
  --secondary <name>         Set the secondary monitor name (desktop only)
  --non-interactive          Fail if required values are missing instead of prompting
  -h, --help                 Show this help message

If no options are provided the script will interactively ask for the details.
EOF
}

DEFAULT_TYPE="desktop"
if compgen -G "/sys/class/power_supply/BAT*" > /dev/null 2>&1; then
    DEFAULT_TYPE="laptop"
fi

MACHINE_TYPE=""
MONITOR_PRIMARY=""
MONITOR_SECONDARY=""
NON_INTERACTIVE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)
            MACHINE_TYPE="$2"
            shift 2
            ;;
        --primary)
            MONITOR_PRIMARY="$2"
            shift 2
            ;;
        --secondary)
            MONITOR_SECONDARY="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

prompt_value() {
    local __var_ref="$1"
    local __prompt="$2"
    local __default="$3"

    if [[ ${!__var_ref} != "" ]]; then
        return
    fi

    if [[ $NON_INTERACTIVE -eq 1 ]]; then
        echo "Missing required value: $__prompt" >&2
        exit 1
    fi

    read -r -p "$__prompt [$__default]: " __input
    if [[ -z "$__input" ]]; then
        __input="$__default"
    fi
    printf -v "$__var_ref" '%s' "$__input"
}

prompt_machine_type() {
    prompt_value MACHINE_TYPE "Is this a laptop or desktop?" "$DEFAULT_TYPE"
    MACHINE_TYPE="${MACHINE_TYPE,,}"
    if [[ "$MACHINE_TYPE" != "laptop" && "$MACHINE_TYPE" != "desktop" ]]; then
        echo "Invalid machine type: $MACHINE_TYPE (expected 'laptop' or 'desktop')" >&2
        exit 1
    fi
}

prompt_monitors_if_needed() {
    if [[ "$MACHINE_TYPE" == "desktop" ]]; then
        if command -v hyprctl >/dev/null 2>&1 && [[ $NON_INTERACTIVE -eq 0 ]]; then
            echo ""
            echo "Detected monitors:"
            hyprctl monitors || true
            echo ""
        fi
        prompt_value MONITOR_PRIMARY "Enter primary monitor name (e.g., DP-3)" ""
        if [[ $NON_INTERACTIVE -eq 1 && -z "$MONITOR_PRIMARY" ]]; then
            echo "Primary monitor is required for desktop in non-interactive mode" >&2
            exit 1
        fi
        if [[ $NON_INTERACTIVE -eq 0 ]]; then
            read -r -p "Enter secondary monitor name (leave blank for single display): " MONITOR_SECONDARY
        fi
    else
        MONITOR_PRIMARY="${MONITOR_PRIMARY:-eDP-1}"
        MONITOR_SECONDARY=""
    fi
}

prompt_machine_type
prompt_monitors_if_needed

cat > "$config_file" <<CONFIG
MACHINE_TYPE=$MACHINE_TYPE
MONITOR_PRIMARY=$MONITOR_PRIMARY
MONITOR_SECONDARY=$MONITOR_SECONDARY
CONFIG

echo ""
echo "Configuration saved to $config_file:"
cat "$config_file"
echo ""
