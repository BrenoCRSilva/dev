#!/usr/bin/env bash
#
# One-time dotfile setup — templates, SSH permissions, lid switch fix
# Phase: 50 - Runs after packages, before dev-env.sh
#
# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "One-time Dotfile Setup"

load_machine_env

repo_root="$(get_repo_root)"

# ─── Git config templates ─────────────────────────────────────────────────────

log_section "Git Configuration"

if [[ -f "$repo_root/env/.gitconfig.template" ]]; then
    execute bash -c "envsubst < '$repo_root/env/.gitconfig.template' > '$HOME/.gitconfig'"
    log_success "Written ~/.gitconfig"
else
    log_warning "No .gitconfig.template found, skipping"
fi

if [[ -f "$repo_root/env/.gitconfig-work.template" ]]; then
    execute bash -c "envsubst < '$repo_root/env/.gitconfig-work.template' > '$HOME/.gitconfig-work'"
    log_success "Written ~/.gitconfig-work"
fi

# ─── SSH config ───────────────────────────────────────────────────────────────

log_section "SSH Configuration"

if [[ -d "$repo_root/env/.ssh" ]]; then
    execute mkdir -p "$HOME/.ssh"
    execute chmod 700 "$HOME/.ssh"

    if [[ -f "$repo_root/env/.ssh/config.template" ]]; then
        execute bash -c "envsubst < '$repo_root/env/.ssh/config.template' > '$HOME/.ssh/config'"
        execute chmod 600 "$HOME/.ssh/config"
        log_success "Written ~/.ssh/config"
    fi
else
    log_info "No SSH config template found, skipping"
fi

# ─── Lid switch fix (laptop only) ────────────────────────────────────────────

if [[ "$MACHINE_TYPE" == "laptop" ]]; then
    log_section "Lid Switch Fix"

    if [[ -f "/etc/systemd/logind.conf.d/lid-switch.conf" ]]; then
        log_info "Lid switch fix already applied, skipping"
    else
        execute sudo mkdir -p /etc/systemd/logind.conf.d
        execute sudo cp "$repo_root/env/.config/systemd/logind-lid-switch.conf" \
            /etc/systemd/logind.conf.d/lid-switch.conf
        execute chmod +x "$repo_root/env/.config/hypr/scripts/handle-lid.sh"
        execute sudo systemctl restart systemd-logind
        log_success "Lid switch fix applied"
    fi
else
    log_info "Skipping lid switch fix (not a laptop)"
fi

print_footer "One-time dotfile setup complete"
