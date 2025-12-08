#!/usr/bin/env bash

set -e

echo "Installing packages..."

# Official repos with pacman
echo "Installing official packages..."
sudo pacman -S --noconfirm --needed - < packages/base.txt
sudo pacman -S --noconfirm --needed - < packages/desktop.txt
sudo pacman -S --noconfirm --needed - < packages/apps.txt

# AUR packages with paru (one by one)
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
