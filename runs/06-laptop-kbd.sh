#!/usr/bin/env bash
#
# Laptop keyboard fixes
# Phase: 05 - Laptop-specific keyboard configuration
#

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

print_header "Laptop Keyboard Fixes"

# Only run on laptop
if ! is_laptop; then
    log_info "Skipping laptop fixes (not a laptop)"
    exit 0
fi

log_section "Creating keyboard resume service"

# Create systemd service to reload keyboard module after suspend
execute sudo tee /etc/systemd/system/keyboard-resume.service > /dev/null <<EOF
[Unit]
Description=Reload keyboard module after suspend
After=suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'modprobe -r atkbd && modprobe atkbd reset=1'

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target
EOF

execute sudo systemctl enable keyboard-resume.service

log_success "Keyboard resume service created and enabled"

echo ""
log_info "Note: If keyboard still doesn't work after suspend, add this to GRUB:"
log_info "  i8042.direct i8042.dumbkbd"

print_footer "Laptop keyboard fixes applied"
