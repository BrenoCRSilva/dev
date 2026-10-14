#!/usr/bin/env bash
shallow_dirs=(
    "$HOME/personal"
    "$HOME/workspace"
)
project_dirs=(
    "$HOME/personal/projects"
    "$HOME/workspace/projects"
)
nvim_dir=(
    "$HOME/personal/projects/dotfiles/env/.config/nvim"
)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
DIRS_FILE="$CONFIG_DIR/tmux-sessionizer/directories"
additional_dirs=()
if [[ -f "$DIRS_FILE" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        expanded=$(eval echo "$line")
        [[ -d "$expanded" ]] && additional_dirs+=("$expanded")
    done < "$DIRS_FILE"
fi

all_found=$(
    {
        for dir in "${shallow_dirs[@]}"; do
            find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
        done
        for dir in "${project_dirs[@]}"; do
            find "$dir" -mindepth 1 -maxdepth 2 -type d 2>/dev/null
        done
        for dir in "${nvim_dir[@]}"; do
            [[ -d "$dir" ]] && echo "$dir"
        done
        for dir in "${additional_dirs[@]}"; do
            echo "$dir"
        done
    } | sort -u
)

selected=$(echo "$all_found" | fzf)
if [[ -z "$selected" ]]; then
    exit 0
fi

start_session_ssh_agent() {
    local name="$1"
    local safe_name="${name//[^A-Za-z0-9_-]/_}"
    SSH_AGENT_DIR="/tmp/dotfiles-ssh-agent-${safe_name}"
    SSH_AGENT_SOCK="$SSH_AGENT_DIR/agent.sock"
    mkdir -p "$SSH_AGENT_DIR"
    rm -f "$SSH_AGENT_SOCK"

    eval "$(ssh-agent -s -a "$SSH_AGENT_SOCK")"
    export SSH_AGENT_DIR
    export SSH_ASKPASS="${SSH_ASKPASS:-ssh-askpass}"
    export SSH_ASKPASS_REQUIRE=force
}

register_session_ssh_agent_cleanup() {
    local name="$1"
    [[ -n "${SSH_AGENT_PID:-}" && -n "${SSH_AGENT_DIR:-}" ]] || return 0
    tmux set-hook -t "$name" session-closed \
        "run-shell 'kill ${SSH_AGENT_PID} 2>/dev/null || true; rm -rf ${SSH_AGENT_DIR}'" 2>/dev/null || true
}

base_name=$(basename "$selected" | tr . _)
if [[ "$selected" == /mnt/* ]]; then
    selected_name="win-${base_name}"
else
    selected_name=$base_name
fi

tmux_running=$(pgrep tmux)

if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
    start_session_ssh_agent "$selected_name"
    tmux new-session \
        -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" \
        -e "SSH_AGENT_PID=$SSH_AGENT_PID" \
        -e "SSH_ASKPASS=$SSH_ASKPASS" \
        -e "SSH_ASKPASS_REQUIRE=$SSH_ASKPASS_REQUIRE" \
        -s "$selected_name" -c "$selected" \; \
        send-keys -t "$selected_name" "nvim" Enter \; \
        new-window -t "$selected_name:2" -c "$selected" "$HOME/.config/tmux/scripts/agent-picker.sh" \; \
        new-window -t "$selected_name:3" -c "$selected" \; \
        select-window -t "$selected_name:1"
    kill "$SSH_AGENT_PID" 2>/dev/null || true
    rm -rf "$SSH_AGENT_DIR"
    exit 0
fi

if ! tmux has-session -t="$selected_name" 2>/dev/null; then
    start_session_ssh_agent "$selected_name"
    tmux new-session \
        -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" \
        -e "SSH_AGENT_PID=$SSH_AGENT_PID" \
        -e "SSH_ASKPASS=$SSH_ASKPASS" \
        -e "SSH_ASKPASS_REQUIRE=$SSH_ASKPASS_REQUIRE" \
        -ds "$selected_name" -c "$selected" \; \
        send-keys -t "$selected_name" "nvim" Enter \; \
        new-window -t "$selected_name:2" -c "$selected" "$HOME/.config/tmux/scripts/agent-picker.sh" \; \
        new-window -t "$selected_name:3" -c "$selected" \; \
        select-window -t "$selected_name:1"
    register_session_ssh_agent_cleanup "$selected_name"
fi

if [[ -z $TMUX ]]; then
    tmux attach-session -t "$selected_name"
else
    tmux switch-client -t "$selected_name"
fi
