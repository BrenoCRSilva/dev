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
readonly NC='\033[0m' # No Color

# Script directory detection
get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

get_repo_root() {
    local script_dir
    script_dir="$(get_script_dir)"
    dirname "$script_dir"
}

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}▶${NC} $1"
    echo "────────────────────────────────────────"
}

# Check if running on a laptop
is_laptop() {
    local repo_root
    repo_root="$(get_repo_root)"
    
    if [[ ! -f "$repo_root/.machine.conf" ]]; then
        return 1
    fi
    
    # shellcheck source=/dev/null
    source "$repo_root/.machine.conf"
    [[ "${MACHINE_TYPE:-}" == "laptop" ]]
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if package is installed (pacman)
is_package_installed() {
    pacman -Q "$1" &> /dev/null
}

# Install packages with pacman (official repo)
install_packages() {
    local packages=("$@")
    log_info "Installing packages: ${packages[*]}"
    sudo pacman -S --noconfirm --needed "${packages[@]}"
}

# Install packages with paru (AUR)
install_aur_packages() {
    local packages=("$@")
    
    if ! command_exists paru; then
        log_error "paru is not installed. Please install paru first."
        return 1
    fi
    
    log_info "Installing AUR packages: ${packages[*]}"
    paru -S --noconfirm --needed "${packages[@]}"
}

# Ensure directory exists
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# Backup file if it exists
backup_file() {
    local file="$1"
    local backup
    
    if [[ -f "$file" ]]; then
        backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warning "Backing up existing file: $file -> $backup"
        cp "$file" "$backup"
    fi
}

# Check if service is enabled
is_service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# Enable and start systemd service
enable_service() {
    local service="$1"
    log_info "Enabling service: $service"
    sudo systemctl enable --now "$service"
}

# Enable user systemd service
enable_user_service() {
    local service="$1"
    log_info "Enabling user service: $service"
    systemctl --user enable --now "$service"
}

# Run command with dry-run support
dry_run="${DRY_RUN:-0}"

execute() {
    if [[ "$dry_run" == "1" ]]; then
        log_info "[DRY RUN] Would execute: $*"
    else
        "$@"
    fi
}

# Print script header
print_header() {
    local script_name="$1"
    echo ""
    echo "════════════════════════════════════════"
    echo "  $script_name"
    echo "════════════════════════════════════════"
    echo ""
}

# Print script footer
print_footer() {
    local message="${1:-Complete!}"
    echo ""
    echo "════════════════════════════════════════"
    log_success "$message"
    echo "════════════════════════════════════════"
    echo ""
}

# Verify prerequisites
verify_prerequisites() {
    local deps=("$@")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command_exists "$dep"; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Check if we're in the correct directory
verify_repo_structure() {
    local repo_root
    repo_root="$(get_repo_root)"
    
    if [[ ! -d "$repo_root/env" ]]; then
        log_error "Not in the correct repository structure"
        log_error "Expected: $repo_root/env directory not found"
        return 1
    fi
    
    return 0
}
