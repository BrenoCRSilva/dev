#!/usr/bin/env bash

# Smart Sync - Handles both dev repo and nvim submodule

set -e

cd ~/personal/dev

# Check if nvim submodule has changes
if [ -d "env/.config/nvim/.git" ]; then
    cd env/.config/nvim
    
    # Check for uncommitted changes in nvim
    if [ -n "$(git status --porcelain)" ]; then
        echo "📝 Nvim submodule has uncommitted changes..."
        git add .
        git commit -m 'automated nvim commit' || echo "Nothing to commit in nvim"
        git push || echo "Push failed or nothing to push in nvim"
        cd ~/personal/dev
        
        # Update the submodule reference in parent repo
        echo "📦 Updating nvim submodule reference..."
        git add env/.config/nvim
        git commit -m 'update nvim submodule' || echo "Submodule already up to date"
    else
        cd ~/personal/dev
        
        # Check if nvim is ahead/behind remote (not committed but pushed elsewhere)
        cd env/.config/nvim
        git fetch origin main 2>/dev/null || true
        if [ "$(git rev-list HEAD..origin/main --count 2>/dev/null || echo 0)" -gt 0 ]; then
            echo "⬇️  Pulling nvim updates..."
            git pull origin main || echo "Pull failed"
            cd ~/personal/dev
            git add env/.config/nvim
            git commit -m 'sync nvim submodule' || true
        else
            cd ~/personal/dev
        fi
    fi
fi

# Commit and push main dev repo
echo "🚀 Syncing main dev repository..."
git add .
git commit -m 'automated dev commit' || echo "Nothing new to commit in dev repo"
git push || echo "Push failed or up to date"

echo "✅ Sync complete!"
