#!/usr/bin/env bash

set -e

echo "🚀 Setting up Cursor with Neovim configuration..."

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

if ! command -v cursor &> /dev/null; then
    echo "❌ Cursor CLI not found. Please install Cursor first."
    echo "   Then run: sudo ln -s /opt/Cursor/cursor /usr/local/bin/cursor"
    exit 1
fi

echo -e "${BLUE}📦 Installing extensions...${NC}"

cursor --install-extension asvetliakov.vscode-neovim
cursor --install-extension deibitx.periscope
cursor --install-extension jasew.cursor-harpoon
cursor --install-extension alefragnani.project-manager
cursor --install-extension eamodio.gitlens
cursor --install-extension mhutchie.git-graph
cursor --install-extension mvllow.rose-pine
cursor --install-extension golang.go
cursor --install-extension ms-python.python
cursor --install-extension ms-python.vscode-pylance
cursor --install-extension ms-python.black-formatter
cursor --install-extension dbaeumer.vscode-eslint
cursor --install-extension esbenp.prettier-vscode
cursor --install-extension mtxr.sqltools
cursor --install-extension dorzey.vscode-sqlfluff
cursor --install-extension JohnnyMorganz.stylua
cursor --install-extension timonwong.shellcheck
cursor --install-extension usernamehw.errorlens

echo -e "${GREEN}✅ All extensions installed!${NC}"

CONFIG_DIR="$HOME/.config/cursor/User"
mkdir -p "$CONFIG_DIR"

echo -e "${BLUE}📝 Deploying configuration files...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -f "$CONFIG_DIR/settings.json" ]; then
    echo -e "${YELLOW}⚠️  settings.json already exists. Creating backup...${NC}"
    cp "$CONFIG_DIR/settings.json" "$CONFIG_DIR/settings.json.backup.$(date +%Y%m%d_%H%M%S)"
fi
cp "$REPO_ROOT/env/.config/cursor/User/settings.json" "$CONFIG_DIR/settings.json"
echo -e "${GREEN}✓${NC} Copied settings.json"

if [ -f "$CONFIG_DIR/keybindings.json" ]; then
    echo -e "${YELLOW}⚠️  keybindings.json already exists. Creating backup...${NC}"
    cp "$CONFIG_DIR/keybindings.json" "$CONFIG_DIR/keybindings.json.backup.$(date +%Y%m%d_%H%M%S)"
fi
cp "$REPO_ROOT/env/.config/cursor/User/keybindings.json" "$CONFIG_DIR/keybindings.json"
echo -e "${GREEN}✓${NC} Copied keybindings.json"

echo ""
echo -e "${GREEN}✅ Setup complete!${NC}"
echo "You can now use 'cursor-sessionizer' to quickly switch projects."
echo "Run 'cursor-sessionizer' to open the picker."
