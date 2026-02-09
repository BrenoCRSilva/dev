#!/usr/bin/env bash

# Script to create desktop entries for PWAs
# Run this after placing your pwa-launch script in ~/.local/bin/

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
LOCAL_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
DESKTOP_DIR="$DATA_DIR/applications"
SCRIPT_PATH="$LOCAL_BIN/pwa-launch"

# Create desktop directory if it doesn't exist
mkdir -p "$DESKTOP_DIR"

# Gmail
cat > "$DESKTOP_DIR/gmail-pwa.desktop" << EOF
[Desktop Entry]
Name=Gmail
Comment=Gmail Web App
Exec=$SCRIPT_PATH gmail
Icon=gmail
Terminal=false
Type=Application
Categories=Network;Email;
StartupWMClass=gmail.com
EOF

# Discord
cat > "$DESKTOP_DIR/discord-pwa.desktop" << EOF
[Desktop Entry]
Name=Discord
Comment=Discord Web App
Exec=$SCRIPT_PATH discord
Icon=discord
Terminal=false
Type=Application
Categories=Network;Chat;
StartupWMClass=discord.com
EOF

# WhatsApp
cat > "$DESKTOP_DIR/whatsapp-pwa.desktop" << EOF
[Desktop Entry]
Name=WhatsApp
Comment=WhatsApp Web App
Exec=$SCRIPT_PATH whatsapp
Icon=whatsapp
Terminal=false
Type=Application
Categories=Network;Chat;
StartupWMClass=web.whatsapp.com
EOF

# YouTube
cat > "$DESKTOP_DIR/youtube-pwa.desktop" << EOF
[Desktop Entry]
Name=YouTube
Comment=YouTube Web App
Exec=$SCRIPT_PATH youtube
Icon=youtube
Terminal=false
Type=Application
Categories=AudioVideo;Video;
StartupWMClass=youtube.com
EOF

echo "Desktop entries created! They should appear in wofi now."
echo "You may need to run: update-desktop-database ~/.local/share/applications"
