# P10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Key bindings
bindkey -v
bindkey "^ " autosuggest-accept

# Environment variables
export PATH="$PATH:/usr/local/go/bin"
export PATH="$PATH:$GOPATH/bin"
export PATH="$PATH:$HOME/.cargo/bin"
export PATH="$PATH:$HOME/.local/bin"
export PATH="$PATH:$HOME/.local/share/nvim/mason/bin"
export GOPATH="$HOME/.local/go"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"  # THIS IS THE KEY LINE
export XDG_CONFIG_HOME="$HOME/.config"
export ZSH_CACHE="$HOME/.cache/zsh"

# Create ZSH cache directory if it doesn't exist
[[ ! -d $ZSH_CACHE ]] && mkdir -p $ZSH_CACHE
export ZSH_COMPDUMP="$ZSH_CACHE/.zcompdump-${SHORT_HOST}-${ZSH_VERSION}"

# Shell options
unsetopt BEEP

# Set the directory we want to store zinit and plugins
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
[ ! -d $ZINIT_HOME ] && mkdir -p "$(dirname $ZINIT_HOME)"
[ ! -d $ZINIT_HOME/.git ] && git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
source "${ZINIT_HOME}/zinit.zsh"

# Load powerlevel10k theme
zinit ice depth=1; zinit light romkatv/powerlevel10k

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Load plugins
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-completions
zinit light zsh-users/zsh-autosuggestions
zinit light Aloxaf/fzf-tab

# Add in snippets
zinit snippet OMZL::git.zsh
zinit snippet OMZP::git

# Load completions
autoload -U compinit && compinit -d $ZSH_COMPDUMP
zinit cdreplay -q

# History configuration
HISTSIZE=5000
HISTFILE="$ZSH_CACHE/zsh_history"
SAVEHIST=$HISTSIZE
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'

# Aliases
alias ls='ls --color'
alias c='clear'
alias b='cd ..'
alias cdwin='cd /mnt/c/Users/breno/'
alias sync='~/personal/dev/sync.sh'
alias tsinit='~/.local/bin/ts-init.sh'

# Shell integrations
eval "$(zoxide init --cmd cd zsh)"
eval $(keychain --eval --quiet id_ed25519 id_ed25519_talqui)

if command -v tmux &> /dev/null && [ -n "$PS1" ] && [[ ! "$TERM" =~ screen ]] && [[ ! "$TERM" =~ tmux ]] && [ -z "$TMUX" ]; then
  tmux a -t home || exec tmux new -s home && exit;
fi

source /usr/share/nvm/init-nvm.sh

# Tmux sessionizer add function
tm-add() {
    local dir="${1:-$(pwd)}"
    dir=$(realpath "$dir" 2>/dev/null || echo "$dir")

    mkdir -p ~/.config/tmux-sessionizer
    echo "$dir" >> ~/.config/tmux-sessionizer/directories
    echo "✓ Added: $dir"
}

# pnpm
export PNPM_HOME="/home/brenocrs/.local/share/pnpm"

case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

. "$HOME/.local/share/../bin/env"
