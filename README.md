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

### Git Configuration

The dotfiles use environment variables for git user configuration. These are stored in `~/.env.local` (which is NOT tracked by git).

**First time setup:**
```bash
# The template was copied to ~/.env.local during installation
# Edit it with your information:
nano ~/.env.local
```

Fill in your details:
```bash
# Personal git config
export GIT_USER_NAME="Your Name"
export GIT_USER_EMAIL="your-personal@email.com"

# Work git config (for talqui projects)
export GIT_WORK_NAME="Your Work Name"
export GIT_WORK_EMAIL="your-work@company.com"
```

Then reload your shell:
```bash
source ~/.zshrc
```

The git configs will automatically use these variables. Work projects in `~/workplace/projects/talqui-*` will use the work configuration.

**Note:** `.env.local` is in `.gitignore` so your personal information stays private and won't be committed.
