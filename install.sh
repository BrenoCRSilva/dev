#!/usr/bin/env bash
#
# Main installation orchestrator for dev environment
# Runs all installation phases in order
#

# shellcheck source=runs/common.sh
source "$(dirname "$0")/runs/common.sh"

print_header "Development Environment Setup"

# Install paru if not present
if ! command_exists paru; then
    log_section "Installing paru (AUR helper)"
    
    execute git clone https://aur.archlinux.org/paru.git ~/paru
    cd ~/paru || exit 1
    execute makepkg -si --noconfirm
    cd - || exit 1
    execute rm -rf ~/paru
    
    log_success "paru installed!"
fi

# Run setup scripts in order
log_section "Phase 1: Interactive Setup"
./run.sh 00-setup

log_section "Phase 2: Package Installation"
./run.sh 01-packages
./run.sh 02-aur-packages

log_section "Phase 3: System Configuration"
./run.sh 03-firewall
./run.sh 04-rustup
./run.sh 05-sddm
./run.sh 06-laptop-kbd
./run.sh 07-lid-switch-fix

log_section "Phase 4: Build from Source"
./run.sh 10-neovim

log_section "Phase 5: Tool Configuration"
./run.sh 20-node
./run.sh 30-zsh
./run.sh 40-cursor

log_section "Phase 6: Deploy Configs"
./dev-env.sh

log_section "Phase 7: Copy Machine Configs"
./run.sh 99-copy-configs

echo ""
echo "════════════════════════════════════════"
log_success "Installation Complete!"
echo "════════════════════════════════════════"
echo ""
log_info "Next steps:"
echo "  1. Log out and log back in (for zsh to take effect)"
echo "  2. Reboot to test SDDM autologin + hyprlock"
echo ""
