#!/usr/bin/env bash
#
# Setup Cursor IDE with extensions and configuration
# Phase: cursor - IDE setup
#

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

print_header "Cursor IDE Setup"

# Verify cursor is installed
if ! command_exists cursor; then
    log_error "Cursor CLI not found. Please install Cursor first."
    log_info "Then run: sudo ln -s /opt/Cursor/cursor /usr/local/bin/cursor"
    exit 1
fi

log_section "Installing extensions"

extensions=(
    asvetliakov.vscode-neovim
    deibitx.periscope
    jasew.cursor-harpoon
    alefragnani.project-manager
    eamodio.gitlens
    mhutchie.git-graph
    mvllow.rose-pine
    golang.go
    ms-python.python
    ms-python.vscode-pylance
    ms-python.black-formatter
    dbaeumer.vscode-eslint
    esbenp.prettier-vscode
    mtxr.sqltools
    dorzey.vscode-sqlfluff
    JohnnyMorganz.stylua
    timonwong.shellcheck
    usernamehw.errorlens
)

for ext in "${extensions[@]}"; do
    log_info "Installing $ext..."
    execute cursor --install-extension "$ext"
done

log_success "All extensions installed"

log_section "Deploying configuration files"

CONFIG_DIR="$HOME/.config/cursor/User"
ensure_dir "$CONFIG_DIR"

repo_root="$(get_repo_root)"

# Backup and copy settings.json
if [[ -f "$CONFIG_DIR/settings.json" ]]; then
    backup_file "$CONFIG_DIR/settings.json"
fi
execute cp "$repo_root/env/.config/cursor/User/settings.json" "$CONFIG_DIR/settings.json"
log_success "Copied settings.json"

# Backup and copy keybindings.json
if [[ -f "$CONFIG_DIR/keybindings.json" ]]; then
    backup_file "$CONFIG_DIR/keybindings.json"
fi
execute cp "$repo_root/env/.config/cursor/User/keybindings.json" "$CONFIG_DIR/keybindings.json"
log_success "Copied keybindings.json"

echo ""
log_success "Setup complete!"
log_info "You can now use 'cursor-sessionizer' to quickly switch projects."
log_info "Run 'cursor-sessionizer' to open the picker."

print_footer "Cursor IDE configured"
