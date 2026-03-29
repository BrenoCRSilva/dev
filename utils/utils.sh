#!/usr/bin/env bash
#
# Common functions for dev environment installation scripts
# Source this file at the beginning of run scripts
#

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Source of truth for machine-specific config
ENV_LOCAL="$HOME/.env.local"

get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

get_repo_root() {
    dirname "$(get_script_dir)"
}

# Logging functions
log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

log_section() {
    echo ""
    echo -e "${BLUE}▶${NC} $1"
    echo "────────────────────────────────────────"
}

# Load ~/.env.local and export machine vars
load_machine_env() {
    if [[ ! -f "$ENV_LOCAL" ]]; then
        log_error "Missing $ENV_LOCAL — run ./runs/00-setup.sh first"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$ENV_LOCAL"
    export MACHINE_TYPE MONITOR_PRIMARY MONITOR_SECONDARY \
           GIT_USER_NAME GIT_USER_EMAIL GIT_WORK_NAME GIT_WORK_EMAIL
}

# Check if running on a laptop
is_laptop() {
    [[ -f "$ENV_LOCAL" ]] || return 1
    # shellcheck source=/dev/null
    source "$ENV_LOCAL"
    [[ "${MACHINE_TYPE:-}" == "laptop" ]]
}

command_exists()     { command -v "$1" &>/dev/null; }
is_package_installed() { pacman -Q "$1" &>/dev/null; }

install_packages() {
    local packages=("$@")
    log_info "Installing packages: ${packages[*]}"
    sudo pacman -S --noconfirm --needed "${packages[@]}"
}

install_aur_packages() {
    local packages=("$@")
    if ! command_exists paru; then
        log_error "paru is not installed."
        return 1
    fi
    log_info "Installing AUR packages: ${packages[*]}"
    paru -S --noconfirm --needed "${packages[@]}"
}

ensure_dir() {
    local dir="$1"
    [[ ! -d "$dir" ]] && mkdir -p "$dir"
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warning "Backing up: $file -> $backup"
        cp "$file" "$backup"
    fi
}

is_service_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

enable_service() {
    log_info "Enabling service: $1"
    sudo systemctl enable --now "$1"
}

enable_user_service() {
    log_info "Enabling user service: $1"
    systemctl --user enable --now "$1"
}

dry_run="${DRY_RUN:-0}"

execute() {
    if [[ "$dry_run" == "1" ]]; then
        log_info "[DRY RUN] Would execute: $*"
    else
        "$@"
    fi
}

print_header() {
    echo ""
    echo "════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════"
    echo ""
}

print_footer() {
    local message="${1:-Complete!}"
    echo ""
    echo "════════════════════════════════════════"
    log_success "$message"
    echo "════════════════════════════════════════"
    echo ""
}

verify_prerequisites() {
    local deps=("$@")
    local missing=()
    for dep in "${deps[@]}"; do
        command_exists "$dep" || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        return 1
    fi
}

verify_repo_structure() {
    local repo_root
    repo_root="$(get_repo_root)"
    if [[ ! -d "$repo_root/env" ]]; then
        log_error "Expected $repo_root/env directory not found"
        return 1
    fi
}
