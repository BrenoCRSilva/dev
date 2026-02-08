#!/usr/bin/env bash
#
# Configure Node.js/npm
# Phase: node - Node.js setup
#

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

print_header "Node.js Configuration"

log_info "Configuring npm prefix..."
execute npm config set prefix ~/.local/npm

log_info "Adding npm bin to PATH..."
if ! grep -q ".local/npm/bin" ~/.zshrc 2>/dev/null; then
    echo "export PATH=\"\$HOME/.local/npm/bin:\$PATH\"" >> ~/.zshrc
    log_success "Added npm bin to ~/.zshrc"
else
    log_info "npm bin already in PATH"
fi

print_footer "Node.js configured"
