#!/usr/bin/env bash

set -e

echo "Setting up Kanata permissions..."

# Load uinput module
sudo modprobe uinput

# Make it load on boot
echo "uinput" | sudo tee /etc/modules-load.d/uinput.conf

# Create uinput group if it doesn't exist
sudo groupadd -f uinput

# Add user to uinput group
sudo usermod -aG uinput $USER

# Set uinput permissions
sudo tee /etc/udev/rules.d/99-uinput.rules > /dev/null <<EOF
KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
EOF

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger

echo "✓ Kanata permissions configured"
echo ""
echo "NOTE: You need to log out and back in for group changes to take effect"
