# Dev Environment Setup

Automated Arch Linux development environment with Hyprland.

## Structure
```
~/personal/
├── dev/           # This repo (configs and install scripts)
└── neovim/        # Neovim source (created during installation)
```

## Prerequisites

### During archinstall

When prompted for "Additional packages", install:
```
git base-devel openssh networkmanager
```

### After first boot
```bash
# Setup SSH keys
ssh-keygen -t ed25519 -C "your-email@example.com"
# Add public key to GitHub: https://github.com/settings/keys

# Clone this repo
mkdir -p ~/personal
cd ~/personal
git clone --recursive git@github.com:your-username/dev.git
cd dev

# Run installation
./install.sh
```

## What it installs

- Hyprland + Waybar + complete desktop environment
- Neovim (built from source in ~/personal/neovim)
- Cursor with vim keybindings
- All dev tools (Node, Go, Rust, Python)
- Configured for laptop OR desktop with dual monitors

## Configuration

The setup script will prompt you for:
- Machine type (laptop/desktop)
- Monitor names (if desktop)

Configs are automatically adapted based on your choices. You can rerun `./machine-conf.sh`
anytime to regenerate `.machine.conf` without going through the entire installer.
