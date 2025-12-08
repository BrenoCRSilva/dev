#!/usr/bin/env bash

set -e

echo "Setting up Zsh..."

CURRENT_USER=${USER:-$(whoami)}
ZSH_PATH=$(which zsh)

if ! grep -q "^$ZSH_PATH$" /etc/shells; then
    echo "$ZSH_PATH" | sudo tee -a /etc/shells
fi

chsh -s "$ZSH_PATH" "$CURRENT_USER"

echo "Zsh set as default shell for $CURRENT_USER"
