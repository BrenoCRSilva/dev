#!/usr/bin/env bash
#
# Install AUR packages
#

# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "Package Installation - AUR"

# Verify paru is installed
if ! command_exists paru; then
    log_error "paru is not installed. Please install paru first."
    log_info "Run: ./install.sh to install paru and all packages"
    exit 1
fi

log_section "AUR Packages"
install_aur_packages \
    kanata-bin \
    cursor-bin \
    bun-bin \
    1password \
    1password-cli \
    spotify-launcher \
    youtube-desktop \
    xpadneo-dkms

print_footer "AUR packages installed successfully"
