#!/usr/bin/env bash

set -e

echo "Setting up Rust with rustup..."

rustup default nightly
rustc --version
cargo --version

echo "Rust nightly installed!"
