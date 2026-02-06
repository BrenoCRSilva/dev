#!/usr/bin/env bash

# Find Chrome executable
if command -v google-chrome &> /dev/null; then
    browser="google-chrome"
elif [ -f ~/.local/share/applications/google-chrome.desktop ] || [ -f /usr/share/applications/google-chrome.desktop ]; then
    browser=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' {~/.local,~/.nix-profile,/usr}/share/applications/google-chrome.desktop 2>/dev/null | head -1)
else
    echo "Error: Chrome not found. Install google-chrome."
    exit 1
fi

# Create app name from URL
app_name=$(echo "$1" | sed 's|https\?://||' | sed 's|/.*||' | sed 's|\.|-|g')

BROWSER=firefox exec setsid uwsm app -- $browser \
    --app="$1" \
    --user-data-dir="$HOME/.config/chrome-apps/$app_name" \
    --enable-features=WebAppEnableExtensions,UseOzonePlatform \
    --ozone-platform=wayland \
    --disable-features=WaylandWpColorManagerV1,MediaRouter \
    --enable-wayland-ime \
    --no-first-run \
    --no-default-browser-check \
    --disable-background-networking \
    "${@:2}"
