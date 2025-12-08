#!/usr/bin/env bash

set -e

echo "Installing packages..."

# Official repos
paru -S --noconfirm --needed - < packages/base.txt
paru -S --noconfirm --needed - < packages/desktop.txt
paru -S --noconfirm --needed - < packages/apps.txt

# AUR packages (one by one)
echo "Installing AUR packages..."
paru -S --noconfirm --needed kanata-bin
paru -S --noconfirm --needed cursor-bin
paru -S --noconfirm --needed bun-bin
paru -S --noconfirm --needed 1password
paru -S --noconfirm --needed 1password-cli
paru -S --noconfirm --needed spotify-launcher
paru -S --noconfirm --needed youtube-desktop
paru -S --noconfirm --needed xpadneo-dkms

echo "Packages installed!"
