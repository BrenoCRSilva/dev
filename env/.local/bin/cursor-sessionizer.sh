#!/usr/bin/env bash

# Cursor Sessionizer - Like tmux sessionizer but for Cursor projects
# Recursively searches directories like tmux sessionizer

# Core directories to search (recursive, 2 levels deep)
core_dirs=(
    "$HOME/personal/projects"
    "$HOME/personal/dev"
    "$HOME/workspace/projects"
)

# Special directories (add directly, no recursion)
special_dirs=(
    "$HOME/personal/dev/env/.config/nvim"
)

# Read additional directories from config file (add directly, no recursion)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
DIRS_FILE="$CONFIG_DIR/tmux-sessionizer/directories"
additional_dirs=()
if [[ -f "$DIRS_FILE" ]]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Expand ~ and variables
        expanded=$(eval echo "$line")
        [[ -d "$expanded" ]] && additional_dirs+=("$expanded")
    done < "$DIRS_FILE"
fi

# Direct open mode - if directory provided as argument
if [ -n "$1" ]; then
    cursor "$1" &
    exit 0
fi

# Build list of directories (recursive search like tmux sessionizer)
all_found=$(
    # Deep search (2 levels) through core directories
    for dir in "${core_dirs[@]}"; do
        [[ -d "$dir" ]] && find "$dir" -mindepth 1 -maxdepth 2 -type d 2>/dev/null
    done
    
    # Add special directories directly (no recursion)
    for dir in "${special_dirs[@]}"; do
        [[ -d "$dir" ]] && echo "$dir"
    done
    
    # Add additional directories from config directly (no recursion)
    for dir in "${additional_dirs[@]}"; do
        echo "$dir"
    done
)

# Show fzf picker (requires interactive terminal)
if command -v fzf &> /dev/null && [ -t 0 ]; then
    DIR=$(echo "$all_found" | sort -u | fzf --prompt="Cursor Session: " --height 40% --preview 'ls -la {}' --preview-window=right:30%)
else
    # Fallback: simple menu (works in non-interactive or without fzf)
    echo "Select a project:"
    echo ""
    # Create array from found directories
    IFS=$'\n' read -r -d '' -a dir_array <<< "$(echo "$all_found" | sort -u)"
    select DIR in "${dir_array[@]}" "Cancel"; do
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
    exit 0
fi

# Expand ~ to home directory
DIR=$(eval echo "$DIR")

if [ ! -d "$DIR" ]; then
    echo "Directory does not exist: $DIR"
    exit 1
fi

echo "Opening Cursor in: $DIR"
cursor "$DIR" &

# If running in tmux, kill the window after opening cursor
if [ -n "$TMUX" ]; then
    sleep 1
    tmux kill-window
fi