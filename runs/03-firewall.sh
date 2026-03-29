#!/usr/bin/env bash
#
# Configure UFW firewall
# Phase: 02 - Security configuration
#

# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "Firewall Configuration"

log_info "Setting up UFW firewall..."

execute sudo ufw enable
execute sudo ufw default deny incoming
execute sudo ufw default allow outgoing
execute sudo systemctl enable ufw

log_success "UFW firewall enabled with default deny incoming"

print_footer "Firewall configured"
