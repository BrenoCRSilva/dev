#!/usr/bin/env bash

set -e

echo "Building Neovim from source..."

mkdir -p ~/personal

git clone https://github.com/neovim/neovim.git ~/personal/neovim
cd ~/personal/neovim
git fetch
git checkout v0.11.3
make CMAKE_BUILD_TYPE=RelWithDebInfo
sudo make install

echo "Neovim installed!"
