#!/usr/bin/env bash
script_dir="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)"
dry="0"
only_configs=()

while [[ $# > 0 ]]; do
    if [[ "$1" == "--dry" ]]; then
        dry="1"
    elif [[ "$1" == "--config" ]]; then
        shift
        only_configs+=("$1")
    fi
    shift
done

log() {
    if [[ $dry == "1" ]]; then
        echo "[DRY_RUN]: $@"
    else
        echo "$@"
    fi
}

execute() {
    log "execute: $@"
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
    
    if [[ "$from" == *"/nvim" ]] && [[ -d "$to/.git" ]]; then
        execute rm -rf "$to"
        execute mkdir -p "$to"
    fi
    
    # Normal copy for everything
    if command -v rsync >/dev/null 2>&1; then
        execute rsync -av "$from/" "$to/"
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
fi

log "--------- dev-env ---------"
