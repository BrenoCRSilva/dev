#!/usr/bin/env bash
#
# Install official repository packages
# Phase: 01 - Core system packages
#

# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "Package Installation - Official Repository"

# Base system packages
log_section "Base System"
install_packages \
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
    zram-generator \
    inetutils \
    keychain

# Fonts
log_section "Fonts"
install_packages \
    ttf-iosevka-nerd \
    ttf-firacode-nerd \
    ttf-jetbrains-mono-nerd \
    noto-fonts-emoji

# Desktop Environment
log_section "Desktop Environment"
install_packages \
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
log_section "Applications"
install_packages \
    firefox \
    steam \
    electron

print_footer "Official packages installed successfully"
