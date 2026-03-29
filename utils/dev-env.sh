#!/usr/bin/env bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dry="0"
only_configs=()
installed_all_configs=0

show_help() {
    local script_name
    script_name="$(basename "$0")"
    cat <<EOF
Usage:
  ./$script_name [options]

What it does:
  - With no --config: installs all files from env/ into your user paths
  - With --config: installs only env/.config/<name> to \$XDG_CONFIG_HOME/<name>

Options:
  -c, --config <name>  Install only the given config (repeatable)
  -d, --dry            Dry run mode (print actions without executing)
  -h, --help           Show this help message and exit

Examples:
  ./$script_name
  ./$script_name --dry
  ./$script_name -c hypr
  ./$script_name -c hypr -c waybar
  ./$script_name --config nvim --dry
EOF

    local config_root="$script_dir/../env/.config"
    if [[ -d "$config_root" ]]; then
        local config_names=()
        for dir in "$config_root"/*/; do
            [[ -d "$dir" ]] && config_names+=("$(basename "$dir")")
        done
        if [[ ${#config_names[@]} -gt 0 ]]; then
            printf "\nAvailable config names:\n"
            printf "  %s\n" "${config_names[@]}"
        fi
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry) dry="1"; shift ;;
        -c|--config)
            if [[ -z "${2:-}" ]] || [[ "${2:0:1}" == "-" ]]; then
                echo "Error: $1 requires a config name" >&2
                show_help; exit 1
            fi
            only_configs+=("$2"); shift 2
            ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Error: Unknown option: $1" >&2; show_help; exit 1 ;;
    esac
done

repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

log() {
    [[ $dry == "1" ]] && echo "[DRY_RUN]: $*" || echo "$@"
}

execute() {
    log "execute: $*"
    [[ $dry == "1" ]] && return
    "$@"
}

ensure_dir() {
    [[ ! -d "$1" ]] && execute mkdir -p "$1"
}

copy_dir() {
    local from="$1" to="$2"
    if [[ ! -d "$from" ]]; then
        log "Warning: Source $from does not exist, skipping"
        return
    fi
    ensure_dir "$to"
    if command -v rsync >/dev/null 2>&1; then
        execute rsync -av --exclude='nvim/.git' --exclude='nvim/.git/**' "$from/" "$to/"
    else
        execute cp -r "$from/." "$to/"
    fi
}

copy_file() {
    local from="$1" to="$2"
    ensure_dir "$to"
    execute cp "$from" "$to/$(basename "$from")"
}

apply_machine_configs() {
    local copy_script="$(dirname "$0")/../runs/99-copy-configs.sh"
    local env_local="$HOME/.env.local"

    if [[ ! -f "$env_local" ]]; then
        log "Note: ~/.env.local not found, skipping machine-specific configs (run ./runs/00-setup.sh)"
        return
    fi

    if [[ ! -x "$copy_script" ]]; then
        log "Warning: $copy_script missing or not executable, skipping machine-specific configs"
        return
    fi

    log "Applying machine-specific configs from ~/.env.local"
    execute "$copy_script"
}

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
LOCAL_BIN="$HOME/.local/bin"

if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    log "Note: Add $LOCAL_BIN to your PATH"
fi

log "--------- local setup ---------"
log "XDG_DATA_HOME:  $XDG_DATA_HOME"
log "XDG_CONFIG_HOME: $XDG_CONFIG_HOME"
log "LOCAL_BIN:      $LOCAL_BIN"

if [[ ${#only_configs[@]} -gt 0 ]]; then
    log "Installing only configs: ${only_configs[*]}"
    for config in "${only_configs[@]}"; do
        config_path="env/.config/$config"
        if [[ -d "$config_path" ]]; then
            log "Installing config: $config"
            copy_dir "$config_path" "$XDG_CONFIG_HOME/$config"
        else
            log "Warning: Config '$config' not found at $config_path"
        fi
    done
else
    log "Installing all configs..."
    copy_dir env/.local/share/applications "$XDG_DATA_HOME/applications"
    copy_dir env/.local/bin "$LOCAL_BIN"
    copy_dir env/.config "$XDG_CONFIG_HOME"
    copy_file env/.zshrc "$HOME"
    installed_all_configs=1
fi

if [[ $installed_all_configs -eq 1 ]]; then
    apply_machine_configs
fi

log "--------- dev-env done ---------"
