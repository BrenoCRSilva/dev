#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/config" "$tmp/data" "$tmp/state" "$tmp/cache" "$tmp/project"
cat > "$tmp/check.lua" <<'LUA'
local repo = os.getenv("DOTFILES_REPO")
local lspconfig = os.getenv("NVIM_LSPCONFIG")
vim.opt.rtp:prepend(lspconfig)

local captured = {}
local notices = {}
local original_notify = vim.notify
vim.notify = function(message, level)
	table.insert(notices, { message = tostring(message), level = level })
	return original_notify(message, level)
end

package.preload["telescope.builtin"] = function()
	return setmetatable({}, { __index = function() return function() end end })
end
package.preload["mason-tool-installer"] = function()
	return { setup = function(opts) captured.tool_installer = opts end }
end
package.preload["mason-lspconfig"] = function()
	return { setup = function(opts) captured.mason = opts end }
end

local spec = dofile(repo .. "/env/.config/nvim/lua/plugins/mason-lspconfig.lua")
spec.config()

assert(vim.lsp.config.rust_analyzer, "rust_analyzer config not registered")
assert(vim.lsp.config["rust-analyzer"] == nil, "hyphenated Rust config identifier is invalid")
assert(vim.lsp.config.rust_analyzer.settings["rust-analyzer"].check.command == "clippy")
assert(vim.lsp.config.rust_analyzer.on_attach, "Rust on_attach was not registered")
assert(vim.lsp.config.lua_ls.on_attach, "lua_ls on_attach was not registered")
assert(vim.lsp.config.stylua.cmd[1] == vim.fn.exepath("stylua"), "StyLua executable mismatch")
assert(vim.lsp.config.stylua.cmd[2] == "--lsp", "StyLua must use --lsp")
assert(vim.fn.executable(vim.lsp.config.stylua.cmd[1]) == 1, "StyLua is unavailable")
assert(vim.lsp.config.qmlls.cmd[1] == "/usr/lib/qt6/bin/qmlls" or vim.fn.executable(vim.lsp.config.qmlls.cmd[1]) == 1,
	"QML server command is unavailable")
assert(vim.lsp.config.qmlls.cmd[2] == "-E", "QML server args are incorrect")
assert(vim.tbl_contains(captured.mason.automatic_enable, "rust_analyzer"), "Rust server is not enabled")
assert(vim.tbl_contains(captured.mason.automatic_enable, "qmlls"), "available QML server is not enabled")
assert(not vim.tbl_contains(captured.mason.ensure_installed, "qmlls"), "system QML server must not be Mason-installed")

-- Exercise the configured language servers with isolated buffers. No user init,
-- plugin manager, Mason installer, or project build is loaded or run.
local root = vim.fn.getcwd()
local lua_file = root .. "/check.lua"
local qml_file = root .. "/check.qml"
vim.fn.writefile({ "local value = 1", "return value" }, lua_file)
vim.fn.writefile({ "import QtQuick", "Item {}" }, qml_file)

local lua_buf = vim.fn.bufadd(lua_file)
vim.fn.bufload(lua_buf)
vim.bo[lua_buf].filetype = "lua"
local qml_buf = vim.fn.bufadd(qml_file)
vim.fn.bufload(qml_buf)
vim.bo[qml_buf].filetype = "qml"

local function config(name, cmd, filetypes, on_attach)
	local base = dofile(lspconfig .. "/lsp/" .. name .. ".lua")
	base.name = name
	base.cmd = cmd or base.cmd
	base.filetypes = filetypes or base.filetypes
	base.on_attach = on_attach
	base.root_dir = root
	return base
end

local lua_ls_cmd = vim.fn.exepath("lua-language-server")
assert(lua_ls_cmd ~= "", "lua-language-server is unavailable")
local lua_ls = config("lua_ls", { lua_ls_cmd }, { "lua" }, vim.lsp.config.lua_ls.on_attach)
local stylua = config("stylua", vim.lsp.config.stylua.cmd, { "lua" }, vim.lsp.config.stylua.on_attach)
local qmlls = config("qmlls", vim.lsp.config.qmlls.cmd, { "qml" }, vim.lsp.config.qmlls.on_attach)

assert(vim.lsp.start(lua_ls, { bufnr = lua_buf }), "lua_ls failed to start")
assert(vim.lsp.start(stylua, { bufnr = lua_buf }), "StyLua LSP failed to start")
assert(vim.lsp.start(qmlls, { bufnr = qml_buf }), "qmlls failed to start")

local function attached(buf, name)
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
		if client.name == name then return true end
	end
	return false
end

assert(vim.wait(20000, function()
	return attached(lua_buf, "lua_ls") and attached(lua_buf, "stylua") and attached(qml_buf, "qmlls")
end, 50), "one or more language servers did not attach")

for _, notice in ipairs(notices) do
	if notice.level and notice.level >= vim.log.levels.WARN then
		error("LSP startup warning: " .. notice.message)
	end
end

for _, client in ipairs(vim.lsp.get_clients()) do
	client:stop(true)
end

-- Simulate a host without either QML server binary. The adapter must omit the
-- QML config/auto-enable entry and surface a specific warning.
local original_executable, original_exepath = vim.fn.executable, vim.fn.exepath
vim.fn.executable = function(path)
	if path == "/usr/lib/qt6/bin/qmlls" then return 0 end
	return original_executable(path)
end
vim.fn.exepath = function(name)
	if name == "qmlls" then return "" end
	return original_exepath(name)
end
notices = {}
local config_mt = getmetatable(vim.lsp.config)
local original_config_call = config_mt.__call
config_mt.__call = function(config_table, name, opts)
	if name == "qmlls" then captured.qml_explicit = opts end
	return original_config_call(config_table, name, opts)
end
spec.config()
config_mt.__call = original_config_call
assert(not vim.tbl_contains(captured.mason.automatic_enable, "qmlls"), "missing QML server was auto-enabled")
assert(captured.qml_explicit == nil, "missing QML server received an invalid explicit config")
assert(notices[#notices] and notices[#notices].message:match("qmlls not found"), "missing QML support was not reported")
vim.fn.executable, vim.fn.exepath = original_executable, original_exepath

print("staged LSP config checks passed: lua_ls, StyLua --lsp, qmlls; Rust id/config verified")
LUA

DOTFILES_REPO="$repo" NVIM_LSPCONFIG="$HOME/.local/share/nvim/lazy/nvim-lspconfig" \
HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
nvim --headless --clean -i NONE -u NONE -c "cd $tmp/project" -l "$tmp/check.lua"
