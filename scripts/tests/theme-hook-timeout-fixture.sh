#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo/env/.config/omarchy/hooks/theme-set.d/reload-nvim"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
runtime="$tmp/runtime"
fake_bin="$tmp/bin"
mkdir -p "$runtime" "$fake_bin"
chmod 700 "$runtime"

cat > "$fake_bin/nvim" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_NVIM_LOG"
sleep 5
EOF
chmod +x "$fake_bin/nvim"

python3 - "$hook" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
assert source.count("timeout 2 nvim --server") == 2
payload = source.split("--remote-send '", 1)[1].split("' >/dev/null", 1)[0]
steps = [
    "vim.loader.reset()",
    'pcall(function() require("lazy.core.cache").reset() end)',
    'package.loaded["omarchy-theme"] = nil',
    'package.loaded["omarchy-colors"] = nil',
    'pcall(function() require("omarchy-theme").reload() end)',
]
positions = [payload.index(step) for step in steps]
assert positions == sorted(positions)
PY

if ! python3 - "$runtime/nvim.unresponsive" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
try:
    sock.bind(sys.argv[1])
except OSError as error:
    print(f"cannot create fixture socket: {error}", file=sys.stderr)
    sys.exit(1)
sock.close()
PY
then
	printf 'theme hook timeout fixture skipped: sandbox disallows UNIX socket creation\n'
	exit 0
fi

start=$SECONDS
if output="$(PATH="$fake_bin:$PATH" FAKE_NVIM_LOG="$tmp/nvim.log" \
	XDG_RUNTIME_DIR="$runtime" "$hook" 2>&1)"; then
	status=0
else
	status=$?
fi
elapsed=$((SECONDS - start))

[[ "$status" -eq 0 ]]
[[ "$elapsed" -lt 5 ]]
[[ "$output" == *'timed out during PID probe; skipping'* ]] \
	|| { printf 'timeout diagnostic missing: %s\n' "$output" >&2; exit 1; }
[[ "$(wc -l < "$tmp/nvim.log")" -eq 1 ]]
grep -q -- '--server .* --remote-expr getpid()' "$tmp/nvim.log"

hook_calls="$(grep -c 'timeout 2 nvim --server' "$hook")"
[[ "$hook_calls" -eq 2 ]]

printf 'theme hook timeout and skip checks passed (%ss)\n' "$elapsed"
