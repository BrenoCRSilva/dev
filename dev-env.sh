#!/usr/bin/env bash
script_dir="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)"
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

Notes:
  - Unknown options fail with an error
  - --config requires a value (for example: -c nvim)
EOF

    local config_root="$script_dir/env/.config"
    if [[ -d "$config_root" ]]; then
        local config_names=()
        local dir
        for dir in "$config_root"/*; do
            [[ -d "$dir" ]] || continue
            config_names+=("$(basename "$dir")")
        done

        if [[ ${#config_names[@]} -gt 0 ]]; then
            printf "\nAvailable config names:\n"
            printf "  %s\n" "${config_names[@]}"
        fi
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry)
            dry="1"
            shift
            ;;
        -c|--config)
            if [[ -z "${2:-}" ]] || [[ "${2:0:1}" == "-" ]]; then
                echo "Error: $1 requires a config name" >&2
                show_help
                exit 1
            fi
            only_configs+=("$2")
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

cd "$script_dir"

log() {
    if [[ $dry == "1" ]]; then
        echo "[DRY_RUN]:" "$@"
    else
        echo "$@"
    fi
}

execute() {
    log "execute:" "$@"
    if [[ $dry == "1" ]]; then
        return
    fi
    "$@"
}

ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        execute mkdir -p "$dir"
    fi
}

copy_dir() {
    local from="$1"
    local to="$2"
    
    if [[ ! -d "$from" ]]; then
        log "Warning: Source directory $from does not exist, skipping"
        return
    fi
    
    ensure_dir "$to"
    
    # Normal copy for everything
    if command -v rsync >/dev/null 2>&1; then
        # Exclude nvim/.git since nvim is a separate git repo
        execute rsync -av --exclude='nvim/.git' --exclude='nvim/.git/**' "$from/" "$to/"
    else
        execute cp -r "$from/." "$to/"
    fi
}

copy_file() {
    from=$1
    to=$2
    name=$(basename $from)
    ensure_dir "$to"
    execute cp $from $to/$name
}

apply_machine_configs() {
    local copy_script="$script_dir/runs/99-copy-configs.sh"

    if [[ ! -f "$script_dir/.machine.conf" ]]; then
        log "Note: .machine.conf not found, skipping machine-specific configs (run ./machine-conf.sh or ./runs/00-setup.sh)"
        return
    fi

    if [[ ! -x "$copy_script" ]]; then
        log "Warning: $copy_script is missing or not executable, skipping machine-specific configs"
        return
    fi

    log "Applying machine-specific configs based on .machine.conf"
    execute "$copy_script"
}

apply_lid_switch_fix() {
    # Only apply on laptops
    if [[ ! -f "$script_dir/.machine.conf" ]]; then
        return
    fi
    
    # shellcheck source=/dev/null
    source "$script_dir/.machine.conf"
    
    if [[ "$MACHINE_TYPE" != "laptop" ]]; then
        return
    fi
    
    # Check if already applied
    if [[ -f "/etc/systemd/logind.conf.d/lid-switch.conf" ]]; then
        return
    fi
    
    log ""
    log "Laptop detected - applying lid switch fix..."
    
    if [[ "$dry" == "1" ]]; then
        log "[DRY_RUN]: Would run: sudo $script_dir/runs/06-lid-switch-fix.sh"
        return
    fi
    
    # Run the lid switch fix script with sudo
    if sudo "$script_dir/runs/06-lid-switch-fix.sh"; then
        log "✓ Lid switch fix applied successfully"
    else
        log "Warning: Failed to apply lid switch fix. Run manually with:"
        log "  sudo ./runs/06-lid-switch-fix.sh"
    fi
}

if [ -z "$XDG_DATA_HOME" ]; then
    echo "no xdg data home"
    echo "using ~/.local/share"
    XDG_DATA_HOME="$HOME/.local/share"
fi

LOCAL_BIN="$HOME/.local/bin"
if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    log "Note: Add $LOCAL_BIN to your PATH in your shell configuration"
    log "Add this line to your ~/.zshrc or ~/.bashrc:"
    log "export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

if [ -z "$XDG_CONFIG_HOME" ]; then
    echo "no xdg config home"
    echo "using ~/.config"
    XDG_CONFIG_HOME=$HOME/.config
fi

log "--------- local setup ---------"
log "XDG_DATA_HOME: $XDG_DATA_HOME"
log "LOCAL_BIN: $LOCAL_BIN"
log "XDG_CONFIG_HOME: $XDG_CONFIG_HOME"

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
    copy_dir env/.local/share/applications $XDG_DATA_HOME/applications
    copy_dir env/.local/bin $LOCAL_BIN
    copy_dir env/.config $XDG_CONFIG_HOME
    copy_file env/.zshrc $HOME

    # Copy .env.local template if user doesn't have one
    if [[ -f "$HOME/.env.local" ]]; then
        source "$HOME/.env.local"
    fi

    if [[ -f "env/.env.local.template" ]]; then
        if [[ ! -f "$HOME/.env.local" ]]; then
            log "Creating .env.local from template..."
            cp env/.env.local.template "$HOME/.env.local"
            log "⚠️  Please edit ~/.env.local with your personal information"
        else
            log ".env.local already exists, skipping template"
        fi
    fi

    # Git configs
    if [[ -f "env/.gitconfig.template" ]]; then
        envsubst < env/.gitconfig.template > "$HOME/.gitconfig"
    fi
    if [[ -f "env/.gitconfig-work.template" ]]; then
        envsubst < env/.gitconfig-work.template > "$HOME/.gitconfig-work"
    fi
    
    
    if [[ -d "env/.ssh" ]]; then
        log "Installing SSH configs..."
        copy_dir env/.ssh $HOME/.ssh
        chmod 700 $HOME/.ssh
        if [[ -f "env/.ssh/config.template" ]]; then
            envsubst < env/.ssh/config.template > "$HOME/.ssh/config"
        fi
        chmod 600 $HOME/.ssh/config 2>/dev/null || true
    fi
    
    installed_all_configs=1
fi

if [[ $installed_all_configs -eq 1 ]]; then
    apply_machine_configs
fi

log "--------- dev-env ---------"
