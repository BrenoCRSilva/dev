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

## Deploying Configs (`utils/dev-env.sh`)

Use `dev-env.sh` to copy tracked files from `env/` into your user directories.

```bash
# Install everything
./utils/dev-env.sh

# Dry run (show actions only)
./utils/dev-env.sh --dry

# Install only selected configs
./utils/dev-env.sh --config hypr
./utils/dev-env.sh -c waybar -c nvim

# Help
./utils/dev-env.sh --help
./utils/dev-env.sh -h
```

### Options

- `-c, --config <name>`: install only `env/.config/<name>` (repeatable)
- `-d, --dry`: print actions without executing
- `-h, --help`: show help and available config names

### Zsh alias and completion

If you use this repo's `.zshrc`, you also get:

- Alias: `dev` -> `~/personal/dev/utils/dev-env.sh`
- Completion: `dev -c <TAB>` suggests config names from `~/personal/dev/env/.config/`

## Sync Behavior (`utils/sync.sh`)

`utils/sync.sh` syncs both repositories when available:

- Main repo: `~/personal/dev`
- Neovim repo: `~/personal/dev/env/.config/nvim` (if it has its own `.git`)

When Neovim changes are present, `sync.sh` creates and pushes a commit in the Neovim repo first, then syncs the main dev repo.

Note: repository detection is git-aware (`git -C <path> rev-parse`), so it works whether `.git` is a directory or a gitdir file.

## Configuration

The setup script will prompt you for:
- Machine type (laptop/desktop)
- Monitor names (if desktop)

Configs are automatically adapted based on your choices. You can rerun `./utils/machine-conf.sh`
anytime to regenerate monitor and machine values in `~/.env.local` without going through the entire installer.

### Git Configuration

The dotfiles use environment variables for git user configuration. These are stored in `~/.env.local` (which is NOT tracked by git).

**First time setup:**
```bash
# Run interactive setup (or run full ./install.sh)
./runs/00-setup.sh

# You can edit values later
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
