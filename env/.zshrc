# P10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Key bindings
bindkey -v
bindkey "^ " autosuggest-accept

# Environment variables
export GOPATH="$HOME/.local/go"
export PATH="$PATH:/usr/local/go/bin"
export QML_IMPORT_PATH="/usr/lib/qt6/qml"
export PATH="$PATH:$GOPATH/bin"
export PATH="$PATH:$HOME/.cargo/bin"
export PATH="$PATH:$HOME/.local/bin"
export PATH="$PATH:$HOME/.local/share/nvim/mason/bin"
export PATH="$PATH:$HOME/.local/npm/bin"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"  # THIS IS THE KEY LINE
export XDG_CONFIG_HOME="$HOME/.config"
export ZSH_CACHE="$HOME/.cache/zsh"
export KUBECONFIG="$HOME/.kube/talqui-k3s.yaml"
export FLUX_SYSTEM_NAMESPACE=flux-base
export EDITOR=nvim
export VISUAL=nvim

# Create ZSH cache directory if it doesn't exist
[[ ! -d $ZSH_CACHE ]] && mkdir -p $ZSH_CACHE
export ZSH_COMPDUMP="$ZSH_CACHE/.zcompdump-${SHORT_HOST}-${ZSH_VERSION}"

# Source user-specific environment variables 
if [[ -f "$HOME/.env.local" ]]; then
    source "$HOME/.env.local"
fi

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
alias sync='~/personal/dev/utils/sync.sh'
alias dev='~/personal/dev/utils/dev-env.sh'
alias setup='~/personal/dev/runs/00-setup.sh'
alias tsinit='~/.local/bin/ts-init.sh'
alias reload='source ~/.zshrc'
alias tmsource='tmux source-file ~/.config/tmux/tmux.conf'
alias agents='~/.config/tmux/scripts/agent-picker.sh'
# One-shot reboot into Windows (Boot0000); next boot returns to Linux.
alias windows='sudo efibootmgr --bootnext 0000 && systemctl reboot'

# dev-env.sh completion
_dev_env() {
    local config_root="$HOME/personal/dev/env/.config"
    local -a configs
    local dir

    if [[ -d "$config_root" ]]; then
        for dir in "$config_root"/*(/N); do
            configs+=("${dir:t}")
        done
    fi

    _arguments \
        '(-c --config)'{-c,--config}'[Install only one config]:config name:->configs' \
        '(-d --dry)'{-d,--dry}'[Dry run mode]' \
        '(-h --help)'{-h,--help}'[Show help message]' && return

    case $state in
        configs)
            _describe -t configs 'config' configs
            ;;
    esac
}

compdef _dev_env dev
compdef _dev_env dev-env.sh


# Omarchy stages the active palette; non-Omarchy shells start without overrides.
_theme_colors="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/shell-colors.zsh"
[[ -r "$_theme_colors" ]] && source "$_theme_colors"
unset _theme_colors

if command -v tmux &> /dev/null && [ -n "$PS1" ] && [[ ! "$TERM" =~ screen ]] && [[ ! "$TERM" =~ tmux ]] && [ -z "$TMUX" ] && [ -z "$HERDR_ENV" ]; then
  tmux a -t home || exec tmux new -s home && exit;
fi

# Tmux sessionizer add function
tm-add() {
    local dir="${1:-$(pwd)}"
    dir=$(realpath "$dir" 2>/dev/null || echo "$dir")

    mkdir -p ~/.config/tmux-sessionizer
    echo "$dir" >> ~/.config/tmux-sessionizer/directories
    echo "✓ Added: $dir"
}

# yazi: launch the file manager, then cd to the dir it was in on exit
function y() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}

# pnpm
export PNPM_HOME="$HOME/.local/share/pnpm"

case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

. "$HOME/.local/share/../bin/env"

export PATH=$PATH:$HOME/.spicetify

# Shell integrations
# Do not prompt from zsh startup; Powerlevel10k instant prompt treats that as console I/O.
eval $(keychain --eval --quiet --noask id_ed25519 id_ed25519_talqui)
eval "$(zoxide init --cmd cd zsh)"

if [[ -o interactive ]]; then
  # Project-local tool versions, matching Omarchy's Bash startup behavior.
  eval "$(mise activate zsh)"

  # Add fzf's widgets without taking over the user's Ctrl-T/Ctrl-R or
  # fzf-tab completion key. Preserve existing bindings in every standard ZLE
  # map, then expose pickers on unused vi-mode Alt-F/Alt-H chords.
  typeset -gA _omarchy_fzf_saved_bindings
  for _omarchy_fzf_map in main viins vicmd emacs; do
    for _omarchy_fzf_key in '^T' '^R' '\ec'; do
      _omarchy_fzf_line="$(bindkey -M "$_omarchy_fzf_map" "$_omarchy_fzf_key" 2>/dev/null)"
      _omarchy_fzf_saved_bindings["$_omarchy_fzf_map|$_omarchy_fzf_key"]="${_omarchy_fzf_line##* }"
    done
  done
  FZF_CTRL_T_COMMAND='' FZF_CTRL_R_COMMAND='' FZF_ALT_C_COMMAND='' source /usr/share/fzf/key-bindings.zsh
  for _omarchy_fzf_map in main viins vicmd emacs; do
    for _omarchy_fzf_key in '^T' '^R' '\ec'; do
      _omarchy_fzf_widget="${_omarchy_fzf_saved_bindings["$_omarchy_fzf_map|$_omarchy_fzf_key"]}"
      [[ -n "$_omarchy_fzf_widget" ]] && bindkey -M "$_omarchy_fzf_map" "$_omarchy_fzf_key" "$_omarchy_fzf_widget"
    done
  done
  zle -N fzf-file-widget
  zle -N fzf-history-widget
  for _omarchy_fzf_map in viins vicmd; do
    bindkey -M "$_omarchy_fzf_map" '\ef' fzf-file-widget
    bindkey -M "$_omarchy_fzf_map" '\eh' fzf-history-widget
  done
  unset _omarchy_fzf_map _omarchy_fzf_key _omarchy_fzf_line _omarchy_fzf_widget _omarchy_fzf_saved_bindings
fi
