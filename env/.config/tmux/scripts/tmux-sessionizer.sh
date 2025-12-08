#!/usr/bin/env bash

# Read directories from config file
DIRS_FILE="$HOME/.config/tmux-sessionizer/directories"

if [[ -f "$DIRS_FILE" ]]; then
    dirs=$(cat "$DIRS_FILE" | envsubst)
else
    # Fallback to hardcoded
    dirs="$HOME/workspace/projects $HOME/personal"
fi

# Find all directories
selected=$(echo "$dirs" | tr ' ' '\n' | xargs -I {} find {} -mindepth 1 -maxdepth 1 -type d 2>/dev/null | fzf)

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
