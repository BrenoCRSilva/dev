#!/usr/bin/env bash
#
# Smart Sync - Handles dev repo and nvim repo with beautiful logging
#

set -e

# Source common.sh for beautiful logging
source "$(dirname "$0")/runs/common.sh"

# Source .env.local if it exists (for git credentials)
if [[ -f "$HOME/.env.local" ]]; then
    source "$HOME/.env.local"
fi

# Set git user config from environment variables if not already set
if [[ -n "${GIT_USER_NAME}" && -n "${GIT_USER_EMAIL}" ]]; then
    git config --global user.name "${GIT_USER_NAME}" 2>/dev/null || true
    git config --global user.email "${GIT_USER_EMAIL}" 2>/dev/null || true
fi

print_header "Dev Environment Sync"

# Function to sync a git repo
sync_repo() {
    local repo_path="$1"
    local repo_name="$2"
    local commit_msg="$3"
    
    log_section "Syncing $repo_name"
    
    pushd "$repo_path" > /dev/null
    
    if [[ -n "$(git status --porcelain)" ]]; then
        log_info "Found uncommitted changes"
        execute git add .
        execute git commit -m "$commit_msg" || log_warning "Nothing to commit"
        execute git push || log_warning "Push failed or up to date"
    else
        log_success "Already up to date"
    fi
    
    popd > /dev/null
}

is_git_repo() {
    local repo_path="$1"
    git -C "$repo_path" rev-parse --is-inside-work-tree > /dev/null 2>&1
}

# Sync nvim repo (separate repository)
NVIM_REPO="$HOME/personal/dev/env/.config/nvim"
if is_git_repo "$NVIM_REPO"; then
    sync_repo "$NVIM_REPO" "Nvim Config" "automated nvim commit"
else
    log_info "Skipping Nvim Config (not a git repository)"
fi

# Sync main dev repo
sync_repo ~/personal/dev "Dev Environment" "automated dev commit"

print_footer "Sync complete!"
