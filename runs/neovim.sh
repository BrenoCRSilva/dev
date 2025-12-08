#!/usr/bin/env bash

set -e

# Check if neovim is already installed and at correct version
if command -v nvim &> /dev/null; then
    CURRENT_VERSION=$(nvim --version | head -n1 | grep -oP 'v\d+\.\d+\.\d+')
    TARGET_VERSION="v0.11.3"
    
    if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
        echo "Neovim $TARGET_VERSION already installed, skipping build"
        exit 0
    else
        echo "Neovim $CURRENT_VERSION found, but need $TARGET_VERSION"
        echo "Rebuilding..."
    fi
fi

echo "Building Neovim from source..."

mkdir -p ~/personal

# Clone if doesn't exist
if [ ! -d ~/personal/neovim ]; then
    git clone https://github.com/neovim/neovim.git ~/personal/neovim
fi

cd ~/personal/neovim
git fetch
git checkout v0.11.3
make CMAKE_BUILD_TYPE=RelWithDebInfo
sudo make install

echo "Neovim installed!"
