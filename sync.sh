#!/usr/bin/env bash

if [ -d "env/.config/nvim/.git" ]; then
    cd env/.config/nvim
    git add . && git commit -m 'automated dev commit' && git push
    cd ~/personal/dev
fi

git add . && git commit -m 'automated dev commit' && git push
