#!/usr/bin/env bash

set -e

# Only run on laptop
if [ ! -f .machine.conf ]; then
    echo "Run 00-setup.sh first"
    exit 1
fi

source .machine.conf

if [ "$MACHINE_TYPE" != "laptop" ]; then
    echo "Skipping laptop fixes (not a laptop)"
    exit 0
fi

echo "Applying laptop-specific fixes..."

# Fix keyboard after suspend
echo "Creating keyboard resume service..."
sudo tee /etc/systemd/system/keyboard-resume.service > /dev/null <<EOF
[Unit]
Description=Reload keyboard module after suspend
After=suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'modprobe -r atkbd && modprobe atkbd reset=1'

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target
EOF

sudo systemctl enable keyboard-resume.service

echo "✓ Laptop fixes applied"
echo ""
echo "Note: If keyboard still doesn't work after suspend, add this to GRUB:"
echo "  i8042.direct i8042.dumbkbd"
echo ""
