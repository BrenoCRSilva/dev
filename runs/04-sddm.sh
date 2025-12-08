#!/usr/bin/env bash

set -e

echo "Configuring SDDM autologin..."

CURRENT_USER=${USER:-$(whoami)}

sudo tee /etc/sddm.conf > /dev/null <<SDDM
[Autologin]
User=$CURRENT_USER
Session=hyprland-uwsm.desktop
SDDM

sudo systemctl enable sddm

echo "SDDM autologin configured for $CURRENT_USER"
