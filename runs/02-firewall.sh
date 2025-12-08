#!/usr/bin/env bash

set -e

echo "Setting up UFW firewall..."

sudo ufw enable
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo systemctl enable ufw

echo "UFW firewall enabled with default deny incoming"
