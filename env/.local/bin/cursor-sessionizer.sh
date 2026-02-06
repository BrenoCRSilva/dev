#!/usr/bin/env bash

# Cursor Sessionizer - Like tmux sessionizer but for Cursor projects
# Usage: cursor-sessionizer [directory]
#   If no directory provided, shows fzf picker from sessionizer directories
#   If directory provided, opens Cursor with that directory

SESSIONIZER_FILE="$HOME/.config/tmux-sessionizer/directories"

# Create sessionizer file if it doesn't exist
if [ ! -f "$SESSIONIZER_FILE" ]; then
    mkdir -p "$(dirname "$SESSIONIZER_FILE")"
    cat > "$SESSIONIZER_FILE" <<'EOF'
~/workspace/projects
~/workspace/talqui-chat
~/personal
~/personal/dev
~/personal/projects
~/personal/dev/.config
EOF
fi

if [ -n "$1" ]; then
    # Direct open mode
    cursor "$1" &
    exit 0
fi

# Picker mode
if command -v fzf &> /dev/null; then
    DIR=$(cat "$SESSIONIZER_FILE" | sort -u | fzf --prompt="Cursor Session: " --height 40% --preview 'ls -la {}' --preview-window=right:30%)
else
    # Fallback: simple menu (works without fzf)
    echo "Select a project:"
    select DIR in $(cat "$SESSIONIZER_FILE" | sort -u) "Cancel"; do
        if [ "$DIR" = "Cancel" ]; then
            exit 0
        fi
        if [ -n "$DIR" ] && [ -d "$DIR" ]; then
            break
        fi
        echo "Invalid directory, try again."
    done
fi

if [ -z "$DIR" ]; then
    echo "No directory selected"
    exit 1
fi

# Expand ~ to home directory
DIR=$(eval echo "$DIR")

if [ ! -d "$DIR" ]; then
    echo "Directory does not exist: $DIR"
    exit 1
fi

echo "Opening Cursor in: $DIR"
cursor "$DIR" &