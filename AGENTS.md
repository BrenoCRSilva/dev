# Dev Environment Agent Context

## Repository Overview

This is a **comprehensive Arch Linux development environment configuration repository** using Hyprland as the Wayland compositor. It contains dotfiles, installation scripts, and machine-specific configurations.

**Location**: `/home/brenocrs/personal/dev/`
**Config Sync Target**: `/home/brenocrs/personal/dev/env/` → `~/.config/`, `~/.local/`, `~/`

## Architecture

```
~/personal/
├── dev/                          # This repository
│   ├── env/                      # Configuration files (source of truth)
│   │   ├── .config/              # Config directories (hypr, waybar, nvim, etc.)
│   │   ├── .local/               # Local binaries and scripts
│   │   └── .zshrc               # Shell configuration
│   ├── runs/                     # Installation phase scripts
│   ├── .machine.conf            # Machine-specific settings (generated)
│   ├── dev-env.sh               # Config deployment script
│   ├── install.sh               # Main installation orchestrator
│   ├── run.sh                   # Script runner utility
│   ├── sync.sh                  # Git sync (commit & push)
│   └── machine-conf.sh          # Interactive machine configuration
│
└── neovim/                      # Neovim source (built from source, NOT in env/)
```

## Core Workflow

### 1. Initial Installation (One-time)
```bash
./install.sh
```
**Phases**:
1. **00-setup** - Interactive machine config (laptop/desktop selection)
2. **01-packages** - Install official repo packages
3. **02-aur-packages** - Install AUR packages (paru required)
4. **03-firewall** - UFW configuration
5. **04-rustup** - Rust toolchain
6. **05-sddm** - Display manager setup
7. **06-laptop-kbd** - Laptop keyboard fixes
8. **07-lid-switch-fix** - Fix keyboard not working after lid close (laptop only)
9. **10-neovim** - Build from source in ~/personal/neovim/
10. **20-node** - Node.js/npm setup
11. **30-zsh** - Shell configuration
12. **40-cursor** - Cursor IDE with vim bindings
13. **dev-env.sh** - Deploy all configs
14. **99-copy-configs** - Machine-specific config deployment

### 2. Daily Config Sync
```bash
# Deploy configs from env/ to system
./dev-env.sh

# Or specific configs only
./dev-env.sh --config hypr
./dev-env.sh --config waybar
./dev-env.sh --config nvim

# Short flags and help
./dev-env.sh -c hypr -c waybar
./dev-env.sh -d
./dev-env.sh -h
```

`dev-env.sh` options:
- `-c, --config <name>`: install only one config (repeatable)
- `-d, --dry`: dry run mode
- `-h, --help`: show usage, examples, and available config names

### 3. Development & Backup
```bash
# Edit configs in env/, then sync to git
# Files are auto-copied TO env/ (not FROM), so manual sync needed:
./sync.sh  # Commits and pushes changes
```

## Machine-Specific Configuration

The `.machine.conf` file controls per-machine variations:

```bash
MACHINE_TYPE=desktop|laptop
MONITOR_PRIMARY=DP-3        # Desktop only
MONITOR_SECONDARY=HDMI-A-1 # Desktop only
```

**Generated configs** (do NOT edit directly, run `./machine-conf.sh`):
- `~/.config/hypr/hyprland.conf` → Symlinks to hyprland-desktop.conf or hyprland-laptop.conf
- `~/.config/waybar/config.jsonc` → Symlinks to config-desktop.jsonc or config-laptop.jsonc

## Key Configurations

### Hyprland (Window Manager)
- **Desktop**: Dual monitor setup with specific workspace assignments
- **Laptop**: Dynamic external monitor support, lid-closed operation
- **Key features**: 
  - `Alt+P` / `Alt+Shift+P` - Monitor mode switching (like Windows+P)
  - `Alt+I` - Keyboard layer cycling
  - `Alt+Space` - Language toggle (US/BR)

### Waybar (Status Bar)
- **Desktop**: Two bars (primary + secondary monitor)
- **Laptop**: Single bar with battery indicator
- **Custom modules**: Keyboard layer/layout indicator, power menu, arch menu

### Neovim
- **Location**: Built from source in `~/personal/neovim/`
- **Config**: Standard lazy.nvim setup in `env/.config/nvim/`
- **Not synced** like other configs - it's a separate git repo

### Critical Scripts
Located in `env/.config/` subdirectories:

**Waybar Scripts**:
- `kb-layer-indicator.sh` - Shows current layer + keyboard layout
- `kb-layer-cycle.sh` - Cycles through keyboard layers
- `kb-layout-watcher.sh` - Background daemon for layout detection

**Wofi Scripts**:
- `wallpaper-menu.sh` - Interactive wallpaper selector
- `arch-menu.sh` - System menu (power, lock, etc.)

**Hypr Scripts**:
- `monitor-mode.sh` - Quick monitor cycling
- `monitor-menu.sh` - Visual monitor configuration menu
- `handle-lid.sh` - Handles lid switch events for laptop (disables internal display when external connected)

## Package Management

### Core Packages (Must Have)
```
hyprland hyprpaper hyprlock hypridle xdg-desktop-portal-hyprland
waybar wofi ghostty zsh tmux thunar
pipewire pipewire-pulse wireplumber pavucontrol
bluez bluez-utils blueberry
networkmanager network-manager-applet iwd
wlr-randr wl-clipboard polkit-kde-agent swaync
```

### AUR Packages
```
cursor-bin zen-browser-bin 1password 1password-cli bun-bin
```

### Build Tools
```
base-devel cmake ninja go nodejs npm pnpm rustup
```

## Common Tasks

### Update All Configs
```bash
cd ~/personal/dev
./dev-env.sh
```

If your shell uses `env/.zshrc`, you can use the alias:
```bash
dev
```

### Update Specific Config
```bash
./dev-env.sh --config hypr
./dev-env.sh --config waybar
./dev-env.sh --config nvim

# Equivalent short form
./dev-env.sh -c hypr -c waybar

# With alias + completion
dev -c hypr
dev -c <TAB>
```

### After Editing Configs
```bash
# If you edited files directly in ~/.config/, copy BACK to env/:
cp ~/.config/hypr/hyprland-desktop.conf env/.config/hypr/
cp ~/.config/waybar/config-desktop.jsonc env/.config/waybar/

# Then commit
./sync.sh
```

### Change Machine Type (Desktop ↔ Laptop)
```bash
./machine-conf.sh  # Re-run interactive setup
./dev-env.sh       # Re-deploy configs
```

## Important Notes for Agents

1. **DO NOT** edit files in `~/.config/` directly unless testing - always edit in `env/.config/` then deploy

2. `env/.config/nvim/` may be a separate git repo. `sync.sh` detects it with a git-aware check (`git -C <path> rev-parse`) and syncs it first, then syncs the main dev repo. If working manually, treat nvim and main dev history as separate repositories.

3. **Machine configs are SYMLINKED** - `~/.config/hypr/hyprland.conf` is a symlink to either `hyprland-desktop.conf` or `hyprland-laptop.conf`

4. **Scripts must be executable** - When creating new scripts in `env/.local/bin/` or `env/.config/*/scripts/`, ensure they're chmod +x

5. **Paru is required** - All AUR packages must be installed via paru (AUR helper)

6. **The `env/` directory is the SOURCE** - Not the destination. Changes flow: `env/` → `~/.config/`, not the reverse.

## Run Scripts Architecture

All installation scripts in `runs/` follow a standardized structure:

### Common Library (`runs/common.sh`)
All scripts source `common.sh` which provides:
- **Logging functions**: `log_info`, `log_success`, `log_warning`, `log_error`, `log_section`
- **Header/Footer**: `print_header`, `print_footer` for consistent formatting
- **Package installation**: `install_packages` (pacman), `install_aur_packages` (paru)
- **System checks**: `is_laptop`, `command_exists`, `is_package_installed`
- **Service management**: `enable_service`, `enable_user_service`
- **Utilities**: `ensure_dir`, `backup_file`, `verify_prerequisites`

### Script Template
```bash
#!/usr/bin/env bash
#
# Brief description of what this script does
# Phase: XX - Phase name
#

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

print_header "Script Name"

# Script logic here...
log_section "Section Name"
install_packages package1 package2

print_footer "Completion message"
```

### Script Naming Convention
- **Numbered phases** (01, 02, etc.): Core system setup
- **Named phases** (neovim, cursor, etc.): Tool-specific setup
- **Special scripts**: `copy-configs.sh`, `common.sh`

### Running Individual Scripts
```bash
./run.sh 01-packages      # Run specific script
./run.sh 01-packages --dry  # Dry run mode
DRY_RUN=1 ./run.sh 01-packages  # Alternative dry run
```

## Directory Structure Reference

```
env/
├── .config/
│   ├── hypr/
│   │   ├── hyprland-desktop.conf    # Dual monitor config
│   │   ├── hyprland-laptop.conf     # Single/dynamic monitor config
│   │   ├── hyprland.conf            # Symlink (generated)
│   │   ├── hyprpaper.conf           # Wallpaper config
│   │   ├── hyprlock.conf            # Lock screen config
│   │   └── scripts/                 # Helper scripts
│   ├── waybar/
│   │   ├── config-desktop.jsonc     # Desktop waybar (2 bars)
│   │   ├── config-laptop.jsonc      # Laptop waybar (1 bar)
│   │   ├── config.jsonc             # Symlink (generated)
│   │   ├── style.css               # Waybar styling
│   │   └── scripts/                 # Custom modules
│   ├── wofi/
│   │   ├── wpp-config               # Wallpaper menu config
│   │   ├── confirm-config           # Confirmation dialog config
│   │   └── scripts/                 # Menu scripts
│   ├── nvim/                        # Neovim config (separate repo)
│   ├── tmux/                        # Tmux configuration
│   └── systemd/
│       └── user/                    # User systemd services
├── .local/
│   └── bin/                         # Custom scripts
│       ├── init-hyprpaper.sh       # Laptop wallpaper init
│       ├── toggle-lock.sh          # Cursor lock toggle
│       └── cursor-sessionizer.sh   # Cursor IDE sessionizer
└── .zshrc                          # Zsh configuration
```

## Troubleshooting

**Waybar not showing keyboard layer updates?**
- Check if `kb-layout-watcher.service` is running: `systemctl --user status kb-layout-watcher`
- Ensure scripts are executable: `ls -la ~/.config/waybar/scripts/`
- Check state files: `cat /tmp/kb-layer-state` and `cat /tmp/kb-current-layout`

**Hyprland configs not applying?**
- Check which config is symlinked: `ls -la ~/.config/hypr/hyprland.conf`
- Verify `.machine.conf` exists and has correct `MACHINE_TYPE`
- Run `./machine-conf.sh` to regenerate

**Wallpaper menu not working?**
- Ensure hyprpaper is running: `pgrep hyprpaper`
- Check wallpapers exist: `ls ~/.config/wallpapers/`
- Ensure scripts are executable and in PATH

**Keyboard not working after closing laptop lid?**
- This is fixed by the `06-lid-switch-fix.sh` installation script
- Check if logind configuration is applied: `cat /etc/systemd/logind.conf.d/lid-switch.conf`
- Verify handle-lid.sh is executable: `ls -la ~/.config/hypr/scripts/handle-lid.sh`
- Restart systemd-logind: `sudo systemctl restart systemd-logind`

## External Dependencies

This repo assumes:
- Arch Linux or derivative
- paru (AUR helper) installed
- Git configured with SSH keys
- Basic system already installed (from archinstall)

**Not included but needed for full functionality:**
- Wallpaper files in `~/.config/wallpapers/` (user must add)
- 1Password account (for 1password-cli)
- SSH keys in `~/.ssh/` (for git operations)
