#!/usr/bin/env bash
#
# Lid switch fix for hypridle
# Phase: 06 - Fix keyboard not working after lid close
#

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

print_header "Lid Switch Fix"

# Only run on laptop
if ! is_laptop; then
    log_info "Skipping lid switch fix (not a laptop)"
    exit 0
fi

log_section "Applying lid switch fix for hypridle"

# Create systemd-logind drop-in directory
execute sudo mkdir -p /etc/systemd/logind.conf.d

# Get repo root for config file path
repo_root="$(get_repo_root)"

# Copy lid switch configuration
execute sudo cp "$repo_root/env/.config/systemd/logind-lid-switch.conf" /etc/systemd/logind.conf.d/lid-switch.conf

# Ensure handle-lid.sh is executable
execute chmod +x "$repo_root/env/.config/hypr/scripts/handle-lid.sh"

# Restart systemd-logind to apply changes
execute sudo systemctl restart systemd-logind

log_success "Lid switch fix applied"

echo ""
log_info "This fix:"
log_info "  - Configures systemd-logind to ignore lid switches"
log_info "  - Lets hypridle handle lid events properly"
log_info "  - Prevents keyboard from stopping after suspend"

print_footer "Lid switch fix complete"
