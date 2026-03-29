#!/usr/bin/env bash
#
# Main installation orchestrator for dev environment
# Runs all installation phases in order
#
# shellcheck source=utils/utils.sh
source "$(dirname "$0")/utils/utils.sh"

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

log_section "Phase 1: Interactive Setup"
./utils/run.sh 00-setup

log_section "Phase 2: Package Installation"
./utils/run.sh 01-packages
./utils/run.sh 02-aur-packages

log_section "Phase 3: System Configuration"
./utils/run.sh 03-firewall
./utils/run.sh 04-rustup
./utils/run.sh 05-sddm
./utils/run.sh 06-laptop-kbd

log_section "Phase 4: Build from Source"
./utils/run.sh 10-neovim

log_section "Phase 5: Tool Configuration"
./utils/run.sh 20-node
./utils/run.sh 30-zsh
./utils/run.sh 40-cursor

log_section "Phase 6: One-time Dotfile Setup"
./utils/run.sh 50-dotfiles

log_section "Phase 7: Deploy Configs"
./utils/dev-env.sh

echo ""
echo "════════════════════════════════════════"
log_success "Installation Complete!"
echo "════════════════════════════════════════"
echo ""
log_info "Next steps:"
echo "  1. Log out and log back in (for zsh to take effect)"
echo "  2. Reboot to test SDDM autologin + hyprlock"
echo ""
