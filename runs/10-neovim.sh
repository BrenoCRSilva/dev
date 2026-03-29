#!/usr/bin/env bash
#
# Build and install Neovim from source
# Phase: neovim - Editor installation
#

# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "Neovim Installation"

readonly TARGET_VERSION="v0.11.3"

# Check if neovim is already installed and at correct version
if command_exists nvim; then
    current_version=$(nvim --version | head -n1 | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
    
    if [[ "$current_version" == "$TARGET_VERSION" ]]; then
        log_success "Neovim $TARGET_VERSION already installed, skipping build"
        exit 0
    else
        log_warning "Neovim $current_version found, but need $TARGET_VERSION"
        log_info "Rebuilding..."
    fi
fi

log_section "Building Neovim from source"

# Ensure personal directory exists
execute mkdir -p ~/personal

# Clone if doesn't exist
if [[ ! -d ~/personal/neovim ]]; then
    log_info "Cloning Neovim repository..."
    execute git clone https://github.com/neovim/neovim.git ~/personal/neovim
fi

cd ~/personal/neovim || exit 1

log_info "Fetching latest changes..."
execute git fetch

log_info "Checking out version $TARGET_VERSION..."
execute git checkout "$TARGET_VERSION"

log_info "Building Neovim..."
execute make CMAKE_BUILD_TYPE=RelWithDebInfo

log_info "Installing Neovim..."
execute sudo make install

log_success "Neovim $TARGET_VERSION installed!"

print_footer "Neovim installation complete"
