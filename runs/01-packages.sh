#!/usr/bin/env bash

set -e

echo "Installing packages..."

# Official repos - read files explicitly
echo "Installing base packages..."
paru -S --noconfirm --needed $(cat packages/base.txt)

echo "Installing desktop packages..."
paru -S --noconfirm --needed $(cat packages/desktop.txt)

echo "Installing apps..."
paru -S --noconfirm --needed $(cat packages/apps.txt)

# AUR packages (one by one with error handling)
echo "Installing AUR packages..."

install_aur() {
    echo "Installing $1..."
    if paru -S --noconfirm --needed "$1"; then
        echo "✓ $1 installed"
    else
        echo "✗ Failed to install $1"
    fi
}

install_aur kanata-bin
install_aur cursor-bin
install_aur bun-bin
install_aur 1password
install_aur 1password-cli
install_aur spotify-launcher
install_aur youtube-desktop
install_aur xpadneo-dkms

echo "Package installation complete!"
