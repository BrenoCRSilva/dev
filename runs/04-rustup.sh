#!/usr/bin/env bash
#
# Setup Rust toolchain
# Phase: 03 - Rust configuration
#

# shellcheck source=../utils/utils.sh
source "$(dirname "$0")/../utils/utils.sh"

print_header "Rust Toolchain Setup"

log_info "Setting up Rust with rustup..."

execute rustup default nightly

log_info "Rust version:"
execute rustc --version

log_info "Cargo version:"
execute cargo --version

print_footer "Rust nightly installed"
