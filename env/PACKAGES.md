# Development Environment Package Analysis

## Core Environment (Essential - Must Install)

### Window Manager & Compositor
- **hyprland** - Wayland compositor (main window manager)
- **hyprpaper** - Wallpaper utility for Hyprland
- **hyprlock** - Screen lock utility
- **hypridle** - Idle management daemon
- **xdg-desktop-portal-hyprland** - Desktop portal integration

### Status Bar & Launcher
- **waybar** - Highly customizable status bar
- **wofi** - Application launcher/menu (similar to rofi)

### Terminal & Shell
- **ghostty** - Fast, modern terminal emulator
- **zsh** - Z shell (with oh-my-zsh/zinit)
- **tmux** - Terminal multiplexer

### File Management
- **thunar** - Lightweight file manager
- **xdg-utils** - Desktop integration utilities

### System Utilities
- **wlr-randr** - Wayland output management (for monitor configuration)
- **wl-clipboard** - Clipboard utilities for Wayland
- **polkit-kde-agent** - Authentication agent
- **swaync** - Notification daemon
- **dunst** - Alternative notification daemon

### Audio
- **pipewire** - Audio/video server
- **pipewire-pulse** - PulseAudio compatibility
- **wireplumber** - PipeWire session manager
- **pavucontrol** - PulseAudio volume control GUI

### Bluetooth
- **bluez** - Bluetooth protocol stack
- **bluez-utils** - Bluetooth utilities
- **blueberry** - Bluetooth configuration tool

### Networking
- **networkmanager** - Network connection manager
- **network-manager-applet** - System tray applet
- **iwd** - iNet wireless daemon

## Development Tools (Highly Recommended)

### Editors & IDEs
- **neovim** - Vim-fork focused on extensibility
- **cursor-bin** - AI-powered code editor

### Version Control
- **git** - Distributed version control
- **keychain** - SSH/GPG key manager

### Build Tools
- **base-devel** - Essential build tools (gcc, make, etc.)
- **cmake** - Cross-platform build system
- **ninja** - Fast build system
- **go** - Go programming language
- **nodejs** - JavaScript runtime
- **npm** - Node package manager
- **pnpm** - Fast package manager
- **bun-bin** - Fast JavaScript runtime

### Terminal Utilities
- **fzf** - Command-line fuzzy finder
- **zoxide** - Smarter cd command
- **btop** - Resource monitor
- **htop** - Interactive process viewer
- **fastfetch** - System information tool
- **jq** - JSON processor
- **grim** - Screenshot utility (Wayland)
- **slurp** - Select region for screenshots
- **flameshot** - Powerful screenshot tool
- **imv** - Image viewer for Wayland

### Fonts
- **ttf-firacode-nerd** - Monospaced font with ligatures
- **ttf-iosevka-nerd** - Narrow programming font
- **noto-fonts-emoji** - Emoji font
- **ttf-ms-fonts** - Microsoft fonts (for compatibility)

## Browser & Web
- **firefox** - Web browser
- **google-chrome** - Web browser (for PWAs/Chrome apps)
- **zen-browser-bin** - Privacy-focused browser

## Theming & Appearance
- **rose-pine-gtk-theme-full** - GTK theme
- **nwg-look** - GTK theme settings for Wayland
- **gnome-themes-extra** - Additional GTK themes
- **gtk-engine-murrine** - GTK2 theme engine

## Optional/Workflow Enhancement

### Media & Entertainment
- **spotify-launcher** - Music streaming
- **steam** - Gaming platform
- **playerctl** - Media player controller

### Productivity
- **libreoffice-fresh** - Office suite
- **1password** - Password manager
- **1password-cli** - 1Password CLI

### Hardware Support
- **sof-firmware** - Intel Sound Open Firmware
- **linux-firmware** - Firmware files
- **intel-ucode** - Intel microcode updates

### Virtualization & Containers
- (Check if you use Docker/Podman)

## Missing from Explicit Install (Dependencies Auto-Installed)

These are likely pulled in as dependencies but worth noting:
- **grimblast** or **hyprshot** - Screenshot tools (check if used)
- **brightnessctl** - Screen brightness control (for laptops)
- **wireless_tools** - Wireless tools

## Quick Install Script Template

```bash
#!/bin/bash
# Install core packages for dev environment

# Update system
sudo pacman -Syu

# Install paru (AUR helper) if not present
if ! command -v paru &> /dev/null; then
    git clone https://aur.archlinux.org/paru.git
    cd paru
    makepkg -si
    cd ..
    rm -rf paru
fi

# Core environment packages
paru -S --needed \
    hyprland hyprpaper hyprlock hypridle hyprshot \
    xdg-desktop-portal-hyprland \
    waybar wofi \
    ghostty zsh tmux \
    thunar xdg-utils \
    wlr-randr wl-clipboard \
    polkit-kde-agent \
    swaync \
    pipewire pipewire-pulse wireplumber pavucontrol \
    bluez bluez-utils blueberry \
    networkmanager network-manager-applet iwd \
    neovim git keychain \
    base-devel cmake ninja go nodejs npm pnpm \
    fzf zoxide btop htop fastfetch jq \
    grim slurp flameshot imv \
    ttf-firacode-nerd ttf-iosevka-nerd noto-fonts-emoji \
    firefox google-chrome \
    rose-pine-gtk-theme-full nwg-look \
    spotify-launcher playerctl \
    sof-firmware linux-firmware

# Start services
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now bluetooth

# Install additional AUR packages
paru -S --needed \
    cursor-bin \
    bun-bin \
    zen-browser-bin \
    1password 1password-cli

# Change shell to zsh
chsh -s $(which zsh)

echo "Installation complete! Please log out and back in for all changes to take effect."
```

## Recommendations

1. **Create an install.sh script** in the dev-env repo root
2. **Document which packages are AUR vs official** to clarify install order
3. **Add service enablement** instructions (NetworkManager, bluetooth, etc.)
4. **Consider separating into categories**: minimal (just to get running) vs full (complete dev setup)
5. **Add a check script** to verify all required binaries are present

## Packages Not Currently in Any List

Based on your install, these are also present but may not be documented:
- **qmk** - QMK keyboard firmware tools
- **vial-appimage** - Vial keyboard configuration
- **uwsm** - Universal Wayland Session Manager
- **wlogout** - Wayland logout menu
- **youtube** - YouTube client (likely a PWA script)
- **opencode-bin** - This AI assistant!
