#!/usr/bin/env bash

set -e

echo "Installing packages..."

paru -S --noconfirm --needed - < packages/base.txt
paru -S --noconfirm --needed - < packages/desktop.txt
paru -S --noconfirm --needed - < packages/apps.txt

echo "Packages installed!"
