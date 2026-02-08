#!/usr/bin/env bash
script_dir="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)"
dry="0"
only_configs=()
installed_all_configs=0

while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--dry" ]]; then
        dry="1"
    elif [[ "$1" == "--config" ]]; then
        shift
        only_configs+=("$1")
    fi
    shift
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
    
    # Git and SSH configs
    if [[ -f "env/.gitconfig" ]]; then
        log "Installing .gitconfig..."
        copy_file env/.gitconfig $HOME
    fi
    if [[ -f "env/.gitconfig-work" ]]; then
        log "Installing .gitconfig-work..."
        copy_file env/.gitconfig-work $HOME
    fi
    if [[ -d "env/.ssh" ]]; then
        log "Installing SSH configs..."
        copy_dir env/.ssh $HOME/.ssh
        chmod 700 $HOME/.ssh
        chmod 600 $HOME/.ssh/config-work 2>/dev/null || true
    fi
    
    # Copy .env.local template if user doesn't have one
    if [[ -f "env/.env.local.template" ]]; then
        if [[ ! -f "$HOME/.env.local" ]]; then
            log "Creating .env.local from template..."
            cp env/.env.local.template "$HOME/.env.local"
            log "⚠️  Please edit ~/.env.local with your personal information"
        else
            log ".env.local already exists, skipping template"
        fi
    fi
    
    installed_all_configs=1
fi

if [[ $installed_all_configs -eq 1 ]]; then
    apply_machine_configs
fi

log "--------- dev-env ---------"
