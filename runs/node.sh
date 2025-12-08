#!/usr/bin/env bash

set -e

echo "Configuring Node.js..."

npm config set prefix ~/.local/npm

if ! grep -q ".local/npm/bin" ~/.zshrc 2>/dev/null; then
    echo 'export PATH="$HOME/.local/npm/bin:$PATH"' >> ~/.zshrc
fi

echo "Node.js configured!"
