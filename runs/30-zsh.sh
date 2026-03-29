#!/usr/bin/env bash
#
# Setup Zsh as default shell
# Phase: zsh - Shell configuration
#

# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "Zsh Shell Setup"

CURRENT_USER=${USER:-$(whoami)}
ZSH_PATH=$(which zsh)

log_info "Checking if zsh is in /etc/shells..."
if ! grep -q "^$ZSH_PATH$" /etc/shells; then
    log_info "Adding zsh to /etc/shells..."
    echo "$ZSH_PATH" | execute sudo tee -a /etc/shells
fi

log_info "Setting zsh as default shell for $CURRENT_USER..."
execute chsh -s "$ZSH_PATH" "$CURRENT_USER"

log_success "Zsh set as default shell for $CURRENT_USER"

print_footer "Zsh configured"
