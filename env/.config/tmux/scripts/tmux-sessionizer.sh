#!/usr/bin/env bash

core_dirs=(
    "$HOME/personal/projects"
    "$HOME/personal/dev"
    "$HOME/workspace/projects"
)

nvim_dir=(
    "$HOME/personal/dev/env/.config/nvim"
)

# Read additional directories from config
DIRS_FILE="$HOME/.config/tmux-sessionizer/directories"
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

# Combine all finds
all_found=$(
    # Deep search (2 levels) - core directories
    for dir in "${core_dirs[@]}"; do
        find "$dir" -mindepth 1 -maxdepth 2 -type d 2>/dev/null
    done
    
    # Special directories - add directly (depth 0)
    for dir in "${nvim_dir[@]}"; do
        [[ -d "$dir" ]] && echo "$dir"
    done
    
    # Additional directories from config - add directly (depth 0)
    for dir in "${additional_dirs[@]}"; do
        echo "$dir"
    done
)

selected=$(echo "$all_found" | fzf)

if [[ -z "$selected" ]]; then
    exit 0
fi

base_name=$(basename "$selected" | tr . _)

# If the path is under /mnt, prepend "win-" to the name
if [[ "$selected" == /mnt/* ]]; then
    selected_name="win-${base_name}"
else
    selected_name=$base_name
fi

tmux_running=$(pgrep tmux)

# If not in tmux and tmux is not running, start a new session with windows
if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
    tmux new-session -s "$selected_name" -c "$selected"  \; \
        send-keys -t "$selected_name" "nvim" Enter \; \
        new-window -t "$selected_name:2" -c "$selected" \; \
        send-keys -t "$selected_name:2" "opencode" Enter \; \
        new-window -t "$selected_name:3" -c "$selected" \; \
        select-window -t "$selected_name:1"
    exit 0
fi

# Create session if it doesn't exist
if ! tmux has-session -t="$selected_name" 2> /dev/null; then
    tmux new-session -ds "$selected_name" -c "$selected" \; \
        send-keys -t "$selected_name" "nvim" Enter \; \
        new-window -t "$selected_name:2" -c "$selected" \; \
        send-keys -t "$selected_name:2" "opencode" Enter \; \
        new-window -t "$selected_name:3" -c "$selected" \; \
        select-window -t "$selected_name:1"
fi

# Switch to the session (works both inside and outside tmux)
if [[ -z $TMUX ]]; then
    tmux attach-session -t "$selected_name"
else
    tmux switch-client -t "$selected_name"
fi
