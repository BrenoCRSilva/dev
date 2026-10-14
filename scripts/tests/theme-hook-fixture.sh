#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$tmp"' EXIT
runtime="$tmp/runtime"
home="$tmp/home"
state="$tmp/state"
mkdir -p "$runtime" "$home" "$state/omarchy/current/theme" "$tmp/new-lua" "$tmp/bin"
chmod 700 "$runtime"
uid="$(id -u)"

# Keep the hook's tmux probe away from any real user tmux server.
cat > "$tmp/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/tmux"

cat > "$tmp/new-lua/pontuarch.lua" <<'EOF'
return {
	reload = function()
		vim.g.new_adapter_reloads = (vim.g.new_adapter_reloads or 0) + 1
		local path = vim.env.XDG_STATE_HOME .. "/omarchy/current/theme/nvim-palette.lua"
		local palette = dofile(path)
		vim.g.new_adapter_background = palette.background
	end,
}
EOF
printf 'return { schema_version = 1, background = "#112233" }\n' > "$state/omarchy/current/theme/nvim-palette.lua"

start_server() {
	local name="$1" socket="$runtime/nvim.$1"
	LUA_PATH="$tmp/new-lua/?.lua;;" XDG_STATE_HOME="$state" nvim --headless --clean -u NONE -i NONE --listen "$socket" \
		--cmd 'lua vim.g.old_adapter_reloads=0; package.loaded["pontuarch"]={reload=function() vim.g.old_adapter_reloads=vim.g.old_adapter_reloads+1 end}' \
		>/dev/null 2>&1 &
	SERVER_PIDS+=("$!")
	SERVER_SOCKETS+=("$socket")
	for _ in {1..100}; do
		if nvim --server "$socket" --remote-expr 'getpid()' >/dev/null 2>&1; then return 0; fi
		sleep 0.05
	done
	printf 'server failed to start: %s\n' "$name" >&2
	return 1
}

remote_expr() {
	nvim --server "$1" --remote-expr "$2"
}

SERVER_PIDS=()
SERVER_SOCKETS=()
start_server first
start_server second

run_hook() {
	HOME="$home" XDG_RUNTIME_DIR="$runtime" XDG_STATE_HOME="$state" PATH="$tmp/bin:$PATH" \
		"$repo/env/.config/omarchy/hooks/theme-set.d/reload-nvim"
}

# Migration case: both instances begin with the old module cached. The hook
# invalidates it and loads the new adapter against Omarchy's staged palette.
run_hook
for socket in "${SERVER_SOCKETS[@]}"; do
	[[ "$(remote_expr "$socket" "luaeval('vim.g.old_adapter_reloads')")" == 0 ]]
	[[ "$(remote_expr "$socket" "luaeval('vim.g.new_adapter_reloads')")" == 1 ]]
	[[ "$(remote_expr "$socket" "luaeval('vim.g.new_adapter_background')")" == '#112233' ]]
done

# A later theme switch uses the same deployed hook and rereads current state.
printf 'return { schema_version = 1, background = "#445566" }\n' > "$state/omarchy/current/theme/nvim-palette.lua"
run_hook
for socket in "${SERVER_SOCKETS[@]}"; do
	[[ "$(remote_expr "$socket" "luaeval('vim.g.old_adapter_reloads')")" == 0 ]]
	[[ "$(remote_expr "$socket" "luaeval('vim.g.new_adapter_reloads')")" == 2 ]]
	[[ "$(remote_expr "$socket" "luaeval('vim.g.new_adapter_background')")" == '#445566' ]]
done

for socket in "${SERVER_SOCKETS[@]}"; do
	nvim --server "$socket" --remote-send '<Cmd>qa!<CR>' >/dev/null 2>&1 || true
done
for pid in "${SERVER_PIDS[@]}"; do wait "$pid" || true; done

printf 'theme hook multi-server migration and switch checks passed\n'
