#!/usr/bin/env bash
# Agent sessionizer tab: pick an agentic code provider, choose whether to
# resume the last session, then launch it. Runs as the tmux window's command
# (not via send-keys, which races shell init). Drops to an interactive shell
# when the agent exits — or when the picker is cancelled — so the tab stays
# usable.
#
# Controls: ↑/↓ or j/k to navigate, 1-9 to jump straight to a provider,
# Enter to confirm, q/Esc to cancel. Resume prompt is a single y/n keypress.

export PATH="$HOME/.local/npm/bin:$HOME/.local/share/../bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.local/share/nvim/mason/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Providers, in display order.
providers=(claude codex opencode)

# --- styling (terminal ANSI colors; Ghostty inherits Omarchy's palette) ---
if [[ -t 1 ]]; then
    c_reset=$'\e[0m'; c_dim=$'\e[2m'; c_bold=$'\e[1m'
    c_heading=$'\e[34m'    # blue — heading
    c_selected=$'\e[94m'   # bright blue — selection
    c_index=$'\e[96m'      # bright cyan — index
    c_muted=$'\e[90m'      # bright black — hints
    c_text=$'\e[39m'       # default foreground
else
    c_reset=; c_dim=; c_bold=; c_heading=; c_selected=; c_index=; c_muted=; c_text=
fi

hide_cursor() { printf '\e[?25l' >&2; }
show_cursor() { printf '\e[?25h' >&2; }

# --- provider menu ---------------------------------------------------------
# Renders an interactive list and returns the chosen provider on stdout, or
# empty string when cancelled.
pick_provider() {
    local sel=0 n=${#providers[@]} key i

    hide_cursor
    trap show_cursor RETURN

    printf '\n  %s%spick your agentic code provider%s\n' "$c_bold" "$c_heading" "$c_reset" >&2
    printf '  %s↑/↓ navigate · 1-%d jump · enter confirm · q cancel%s\n\n' \
        "$c_muted" "$n" "$c_reset" >&2

    while true; do
        # draw the list
        for ((i = 0; i < n; i++)); do
            if ((i == sel)); then
                printf '  %s%s ❯ %s%-12s%s\e[K\n' \
                    "$c_selected" "$c_bold" "" "${providers[i]}" "$c_reset" >&2
            else
                printf '    %s%d%s %s%-12s%s\e[K\n' \
                    "$c_index" "$((i + 1))" "$c_reset" "$c_text" "${providers[i]}" "$c_reset" >&2
            fi
        done

        # read one keystroke (handles escape sequences for arrows)
        IFS= read -rsn1 key
        if [[ $key == $'\e' ]]; then
            read -rsn2 -t 0.001 rest
            key+=$rest
        fi

        case "$key" in
            $'\e[A'|k) ((sel = (sel - 1 + n) % n)) ;;       # up
            $'\e[B'|j) ((sel = (sel + 1) % n)) ;;           # down
            [1-9])
                if ((key >= 1 && key <= n)); then
                    printf '%s' "${providers[key - 1]}"
                    return
                fi ;;
            ''|$'\n') printf '%s' "${providers[sel]}"; return ;;  # enter
            q|$'\e') return ;;                              # cancel
        esac

        # move cursor back up to redraw the list in place
        printf '\e[%dA' "$n" >&2
    done
}

# --- resume prompt ---------------------------------------------------------
# Single y/n keypress. Defaults to no.
ask_resume() {
    local agent=$1 key
    printf '\n  %sresume last %s%s%s session? %s[y/N]%s ' \
        "$c_text" "$c_selected" "$agent" "$c_text" "$c_muted" "$c_reset" >&2
    IFS= read -rsn1 key
    printf '\n' >&2
    [[ $key == y || $key == Y ]]
}

# --- main ------------------------------------------------------------------
# A task's orchestrator workspace (TASK_ROLE set by task-sessionizer.sh)
# offers only the providers task-agent.sh supports; it sets the model, effort,
# role prompt and kickoff, and the agents the orchestrator starts follow the
# same provider.
if [[ "${TASK_ROLE:-}" == orchestrator ]]; then
    providers=(claude codex)
    agent=$(pick_provider)
    if [[ -n "$agent" ]]; then
        task_agent="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/task-agent.sh"
        if ask_resume "$agent"; then
            "$task_agent" --provider "$agent" orchestrator --resume
        else
            "$task_agent" --provider "$agent" orchestrator
        fi
    fi
else
    agent=$(pick_provider)
    if [[ -n "$agent" ]]; then
        if ask_resume "$agent"; then resume=yes; else resume=no; fi
        case "$agent" in
            claude)
                [[ "$resume" == yes ]] && claude -c || claude ;;
            codex)
                [[ "$resume" == yes ]] && codex resume --last || codex ;;
            opencode)
                [[ "$resume" == yes ]] && opencode --continue || opencode ;;
        esac
    fi
fi

exec "${SHELL:-/bin/zsh}" -i
