#!/usr/bin/env bash

set -e

echo "Installing official repository packages..."

# Base packages
sudo pacman -S --noconfirm --needed \
    git \
    base-devel \
    openssh \
    networkmanager \
    zsh \
    tmux \
    btop \
    htop \
    nano \
    ripgrep \
    fzf \
    jq \
    curl \
    wget \
    zoxide \
    eza \
    fd \
    bat \
    rsync \
    unzip \
    zip \
    7zip \
    lsof \
    ttf-iosevka-nerd \
    ttf-firacode-nerd \
    ttf-jetbrains-mono-nerd \
    noto-fonts-emoji \
    zram-generator \
    inetutils \
    keychain

# Desktop packages
sudo pacman -S --noconfirm --needed \
    hyprland \
    xdg-desktop-portal-hyprland \
    xdg-desktop-portal-gtk \
    hyprlock \
    hypridle \
    hyprpaper \
    hyprshot \
    waybar \
    swaync \
    wofi \
    brightnessctl \
    playerctl \
    pavucontrol \
    polkit-kde-agent \
    wl-clipboard \
    network-manager-applet \
    fastfetch \
    thunar \
    thunar-volman \
    gvfs \
    gvfs-mtp \
    tumbler \
    nwg-look \
    imv \
    zenity \
    mesa \
    vulkan-radeon \
    xf86-video-amdgpu \
    xf86-video-ati \
    xorg-xwayland \
    xorg-server-common \
    pipewire \
    wireplumber \
    gst-plugins-base \
    gst-plugins-ugly \
    bluez \
    bluez-utils \
    blueberry \
    sddm \
    qt6-wayland \
    gnome-themes-extra \
    sof-firmware \
    ufw \
    cmake \
    gettext \
    lua51 \
    luarocks \
    luajit \
    nodejs \
    npm \
    go \
    rustup \
    ghostty \
    ccache \
    dkms

# Applications
sudo pacman -S --noconfirm --needed \
    firefox \
    steam \
    electron

echo "✓ Official packages installed!"
