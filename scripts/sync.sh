#!/usr/bin/env bash
set -euo pipefail
ROOT="$(realpath -e "$(dirname "${BASH_SOURCE[0]}")/..")"
exec "$ROOT/scripts/envctl" sync "$@"
