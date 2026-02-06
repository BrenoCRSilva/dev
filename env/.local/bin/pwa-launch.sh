#!/usr/bin/env bash

find_chrome() {
    for chrome in google-chrome google-chrome-stable chrome; do
        if command -v "$chrome" &> /dev/null; then
            echo "$chrome"
            return 0
        fi
    done
    
    for path in /usr/bin/google-chrome /opt/google/chrome/chrome; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    echo "Error: Google Chrome not found" >&2
    exit 1
}

launch_app() {
    local app_name="$1"
    local url="$2"
    local workspace="$3"
    local chrome_bin=$(find_chrome)
    
    echo "Launching $app_name..."
    
    if [ -n "$workspace" ]; then
        hyprctl dispatch workspace "$workspace"
    fi
    
    BROWSER=firefox exec setsid "$chrome_bin" \
        --app="$url" \
        --user-data-dir="$HOME/.config/chrome-apps/$app_name" \
        --enable-features=WebAppEnableExtensions,UseOzonePlatform \
        --ozone-platform=wayland \
        --disable-features=WaylandWpColorManagerV1,MediaRouter \
        --enable-wayland-ime \
        --no-first-run \
        --no-default-browser-check \
        --disable-background-networking \
         > /dev/null 2>&1 &
}

case "$1" in
    gmail)
        launch_app "gmail" "https://mail.google.com" 8
        ;;
    discord)
        launch_app "discord" "https://discord.com/app" 7
        ;;
    whatsapp)
        launch_app "whatsapp" "https://web.whatsapp.com" 7
        ;;
    spotify)
        launch_app "spotify" "https://open.spotify.com" 10
        ;;
    teams)
        launch_app "teams" "https://teams.microsoft.com" 9
        ;;
    outlook)
        launch_app "outlook" "https://outlook.office.com" 8
        ;;
    claude)
        launch_app "claude" "https://claude.ai" 5
        ;;
    chatgpt)
        launch_app "chatgpt" "https://chatgpt.com" 5
        ;;
    gemini)
        launch_app "gemini" "https://gemini.google.com" 5
        ;;
    copilot)
        launch_app "copilot" "https://copilot.microsoft.com" 5
        ;;
    *)
        echo "Usage: $0 {gmail|discord|whatsapp|spotify|teams|outlook|claude|chatgpt|gemini|copilot}"
        exit 1
        ;;
esac
