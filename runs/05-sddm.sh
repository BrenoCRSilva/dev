#!/usr/bin/env bash
#
# Configure SDDM display manager with autologin
# Phase: 04 - Display manager setup
#

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

print_header "SDDM Display Manager Setup"

log_info "Configuring SDDM autologin..."

CURRENT_USER=${USER:-$(whoami)}

execute sudo tee /etc/sddm.conf > /dev/null <<SDDM
[Autologin]
User=$CURRENT_USER
Session=hyprland-uwsm.desktop
SDDM

log_info "Enabling SDDM service..."
execute sudo systemctl enable sddm

log_success "SDDM autologin configured for $CURRENT_USER"

print_footer "SDDM configured"
