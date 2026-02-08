# Package Documentation

This document lists all packages installed by the dev environment setup scripts.

## Table of Contents

- [Core System](#core-system)
- [Desktop Environment](#desktop-environment)
- [Development Tools](#development-tools)
- [Applications](#applications)
- [AUR Packages](#aur-packages)

---

## Core System

### Base Utilities
| Package | Description | Script |
|---------|-------------|--------|
| `git` | Version control system | 01-packages |
| `base-devel` | Base development tools (make, gcc, etc.) | 01-packages |
| `openssh` | SSH client and server | 01-packages |
| `networkmanager` | Network connection manager | 01-packages |
| `zsh` | Z shell | 01-packages |
| `tmux` | Terminal multiplexer | 01-packages |
| `btop` | System resource monitor | 01-packages |
| `htop` | Interactive process viewer | 01-packages |
| `nano` | Simple text editor | 01-packages |
| `ripgrep` | Fast grep alternative | 01-packages |
| `fzf` | Fuzzy finder | 01-packages |
| `jq` | JSON processor | 01-packages |
| `curl` | URL transfer tool | 01-packages |
| `wget` | File download utility | 01-packages |
| `zoxide` | Smarter cd command | 01-packages |
| `eza` | Modern ls replacement | 01-packages |
| `fd` | Fast find alternative | 01-packages |
| `bat` | Cat with syntax highlighting | 01-packages |
| `rsync` | File synchronization | 01-packages |
| `unzip` | ZIP archive extractor | 01-packages |
| `zip` | ZIP archive creator | 01-packages |
| `7zip` | 7z archive support | 01-packages |
| `lsof` | List open files | 01-packages |
| `zram-generator` | ZRAM swap configuration | 01-packages |
| `inetutils` | Network utilities | 01-packages |
| `keychain` | SSH key manager | 01-packages |

### Fonts
| Package | Description | Script |
|---------|-------------|--------|
| `ttf-iosevka-nerd` | Iosevka Nerd Font | 01-packages |
| `ttf-firacode-nerd` | Fira Code Nerd Font | 01-packages |
| `ttf-jetbrains-mono-nerd` | JetBrains Mono Nerd Font | 01-packages |
| `noto-fonts-emoji` | Emoji font support | 01-packages |

---

## Desktop Environment

### Hyprland Ecosystem
| Package | Description | Script |
|---------|-------------|--------|
| `hyprland` | Wayland compositor | 01-packages |
| `xdg-desktop-portal-hyprland` | Desktop integration portal | 01-packages |
| `xdg-desktop-portal-gtk` | GTK portal backend | 01-packages |
| `hyprlock` | Screen locker | 01-packages |
| `hypridle` | Idle management daemon | 01-packages |
| `hyprpaper` | Wallpaper utility | 01-packages |
| `hyprshot` | Screenshot tool | 01-packages |

### Wayland Utilities
| Package | Description | Script |
|---------|-------------|--------|
| `waybar` | Status bar | 01-packages |
| `swaync` | Notification daemon | 01-packages |
| `wofi` | Application launcher | 01-packages |
| `brightnessctl` | Brightness control | 01-packages |
| `playerctl` | Media player control | 01-packages |
| `pavucontrol` | PulseAudio volume control | 01-packages |
| `polkit-kde-agent` | Authentication agent | 01-packages |
| `wl-clipboard` | Clipboard utilities | 01-packages |
| `network-manager-applet` | NetworkManager tray icon | 01-packages |

### Display & Graphics
| Package | Description | Script |
|---------|-------------|--------|
| `mesa` | OpenGL drivers | 01-packages |
| `vulkan-radeon` | Vulkan drivers for AMD | 01-packages |
| `xf86-video-amdgpu` | AMD Xorg driver | 01-packages |
| `xf86-video-ati` | ATI Xorg driver | 01-packages |
| `xorg-xwayland` | XWayland support | 01-packages |
| `xorg-server-common` | Xorg server | 01-packages |
| `qt6-wayland` | Qt6 Wayland support | 01-packages |

### Audio
| Package | Description | Script |
|---------|-------------|--------|
| `pipewire` | Audio server | 01-packages |
| `wireplumber` | PipeWire session manager | 01-packages |
| `gst-plugins-base` | GStreamer plugins | 01-packages |
| `gst-plugins-ugly` | GStreamer plugins | 01-packages |
| `bluez` | Bluetooth stack | 01-packages |
| `bluez-utils` | Bluetooth utilities | 01-packages |
| `blueberry` | Bluetooth manager | 01-packages |
| `sof-firmware` | Sound Open Firmware | 01-packages |

### File Management
| Package | Description | Script |
|---------|-------------|--------|
| `thunar` | File manager | 01-packages |
| `thunar-volman` | Volume management | 01-packages |
| `gvfs` | Virtual filesystem | 01-packages |
| `gvfs-mtp` | MTP support | 01-packages |
| `tumbler` | Thumbnail service | 01-packages |

### System Utilities
| Package | Description | Script |
|---------|-------------|--------|
| `fastfetch` | System information | 01-packages |
| `nwg-look` | GTK theme switcher | 01-packages |
| `imv` | Image viewer | 01-packages |
| `zenity` | Dialog boxes | 01-packages |
| `gnome-themes-extra` | GTK themes | 01-packages |
| `sddm` | Display manager | 01-packages |
| `ufw` | Firewall | 01-packages |

---

## Development Tools

### Build Tools
| Package | Description | Script |
|---------|-------------|--------|
| `cmake` | Build system | 01-packages |
| `gettext` | Internationalization | 01-packages |
| `ccache` | Compiler cache | 01-packages |
| `dkms` | Dynamic kernel module support | 01-packages |

### Languages & Runtimes
| Package | Description | Script |
|---------|-------------|--------|
| `lua51` | Lua 5.1 | 01-packages |
| `luarocks` | Lua package manager | 01-packages |
| `luajit` | Lua JIT compiler | 01-packages |
| `nodejs` | Node.js runtime | 01-packages |
| `npm` | Node package manager | 01-packages |
| `go` | Go compiler | 01-packages |
| `rustup` | Rust toolchain installer | 01-packages |

### Terminal
| Package | Description | Script |
|---------|-------------|--------|
| `ghostty` | Terminal emulator | 01-packages |

---

## Applications

| Package | Description | Script |
|---------|-------------|--------|
| `firefox` | Web browser | 01-packages |
| `steam` | Gaming platform | 01-packages |
| `electron` | Electron runtime | 01-packages |

---

## AUR Packages

| Package | Description | Script |
|---------|-------------|--------|
| `kanata-bin` | Keyboard remapping daemon | 01.5-aur-packages |
| `cursor-bin` | Cursor IDE | 01.5-aur-packages |
| `bun-bin` | Bun JavaScript runtime | 01.5-aur-packages |
| `1password` | Password manager | 01.5-aur-packages |
| `1password-cli` | 1Password CLI | 01.5-aur-packages |
| `spotify-launcher` | Spotify client | 01.5-aur-packages |
| `youtube-desktop` | YouTube desktop app | 01.5-aur-packages |
| `xpadneo-dkms` | Xbox controller driver | 01.5-aur-packages |

---

## Installation Order

1. **00-setup** - Machine configuration
2. **01-packages** - Official repository packages
3. **01.5-aur-packages** - AUR packages (requires paru)
4. **02-firewall** - UFW configuration
5. **03-rustup** - Rust toolchain setup
6. **04-sddm** - Display manager setup
7. **05-laptop-kbd** - Laptop keyboard fixes
8. **06-lid-switch-fix** - Lid switch fix for hypridle
9. **neovim** - Build from source
10. **node** - Node.js setup
11. **zsh** - Shell configuration
12. **cursor** - Cursor IDE setup
13. **copy-configs** - Machine-specific config deployment

---

## Notes

- All official packages are installed with `sudo pacman -S --noconfirm --needed`
- AUR packages require `paru` to be installed first
- Some packages are grouped logically but installed in separate commands for clarity
- Laptop-specific fixes are only applied when `MACHINE_TYPE=laptop` in `.machine.conf`
