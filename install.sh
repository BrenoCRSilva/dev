#!/usr/bin/env bash

set -e

echo "================================"
echo "  Dev Environment Setup"
echo "================================"
echo ""

# Install paru if not present
if ! command -v paru &> /dev/null; then
    echo "=== Installing paru ==="
    git clone https://aur.archlinux.org/paru.git ~/paru
    pushd ~/paru
    makepkg -si --noconfirm
    popd
    rm -rf ~/paru
    echo "paru installed!"
    echo ""
fi

# Run setup scripts in order
echo "=== Phase 1: Interactive Setup ==="
./run.sh 00-setup

echo ""
echo "=== Phase 2: Package Installation ==="
./run.sh 01-packages

echo ""
echo "=== Phase 3: System Configuration ==="
./run.sh 02-firewall
./run.sh 03-rustup
./run.sh 04-sddm
./run.sh 05-laptop-kbd

echo ""
echo "=== Phase 4: Build from Source ==="
./run.sh neovim

echo ""
echo "=== Phase 5: Tool Configuration ==="
./run.sh node
./run.sh zsh
./run.sh cursor

echo ""
echo "=== Phase 6: Deploy Configs ==="
./dev-env.sh

echo ""
echo "=== Phase 7: Copy Machine Configs ==="
./run.sh copy-configs

echo ""
echo "================================"
echo "  Installation Complete!"
echo "================================"
echo ""
echo "Next steps:"
echo "  1. Log out and log back in (for zsh to take effect)"
echo "  2. Reboot to test SDDM autologin + hyprlock"
echo ""
