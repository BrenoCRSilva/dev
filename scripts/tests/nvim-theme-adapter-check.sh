#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/config" "$tmp/data" "$tmp/state/omarchy/current/theme" "$tmp/cache" "$tmp/runtime/colors"

for scheme in catppuccin-mocha catppuccin-latte rose-pine-main rose-pine-dawn; do
	cat > "$tmp/runtime/colors/$scheme.lua" <<EOF
if vim.g.TEST_NATIVE_UNAVAILABLE and "$scheme" ~= "rose-pine-main" and "$scheme" ~= "rose-pine-dawn" then
	error("simulated missing native colorscheme plugin")
end
vim.g.last_colorscheme = "$scheme"
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x111111 })
vim.api.nvim_set_hl(0, "String", { fg = 0x00ff00 })
EOF
done
cp "$tmp/runtime/colors/rose-pine-main.lua" "$tmp/runtime/colors/rose-pine.lua"

cat > "$tmp/check.lua" <<'LUA'
local repo = os.getenv("DOTFILES_REPO")
vim.opt.rtp:prepend(os.getenv("TEST_RUNTIME"))
package.path = repo .. "/env/.config/nvim/lua/?.lua;" .. package.path

local native_loads = {}
package.preload["lazy"] = function()
	return { load = function(opts)
		local plugin = opts.plugins[1]
		table.insert(native_loads, plugin)
		if vim.g.TEST_NATIVE_UNAVAILABLE then error("simulated absent plugin") end
	end }
end
local rose_calls = {}
package.preload["rose-pine"] = function()
	return { setup = function(opts) table.insert(rose_calls, vim.deepcopy(opts)) end }
end

local lualine_calls = {}
package.preload["lualine"] = function()
	return { setup = function(opts) table.insert(lualine_calls, vim.deepcopy(opts)) end }
end
package.preload["lualine.themes.auto"] = function()
	return {
		normal = { a = { fg = "#111111", bg = "#222222" }, b = { fg = "#333333", bg = "#444444" }, c = { fg = "#555555", bg = "#666666" } },
		insert = { a = {}, b = {}, c = {} }, visual = { a = {}, b = {}, c = {} },
		replace = { a = {}, b = {}, c = {} }, command = { a = {}, b = {}, c = {} },
		terminal = { a = {}, b = {}, c = {} }, inactive = { a = {}, b = {}, c = {} },
	}
end
local notify_calls = {}
local notify = setmetatable({
	setup = function(opts) table.insert(notify_calls, vim.deepcopy(opts)) end,
}, { __call = function() end })
package.preload["notify"] = function() return notify end
package.preload["noice"] = function() return { setup = function() end } end

local palette_file = vim.env.XDG_STATE_HOME .. "/omarchy/current/theme/nvim-palette.lua"
local theme_file = vim.env.XDG_STATE_HOME .. "/omarchy/current/theme.name"
local function write_state(theme, mode, background, surface, foreground)
	vim.fn.writefile({ theme }, theme_file)
	vim.fn.writefile({
		"return {",
		string.format(' schema_version = 1, mode = "%s", background = "%s", surface = "%s",', mode, background, surface),
		string.format(' foreground = "%s", subtle = "#aaaaaa", muted = "#888888", red = "#ff0000",', foreground),
		' yellow = "#ffff00", green = "#00ff00", cyan = "#00ffff", blue = "#0000ff", magenta = "#ff00ff"',
		"}",
	}, palette_file)
end

local adapter = require("omarchy-theme")
local applied_events = 0
vim.api.nvim_create_autocmd("User", {
	pattern = "OmarchyThemeApplied",
	callback = function() applied_events = applied_events + 1 end,
})

-- Actual active Omarchy Catppuccin theme selects the personal native flavor.
write_state("catppuccin", "dark", "#1e1e2e", "#313244", "#cdd6f4")
adapter.apply()
assert(adapter.palette().colorscheme == "catppuccin-mocha")
assert(vim.g.last_colorscheme == "catppuccin-mocha")
assert(native_loads[#native_loads] == "catppuccin")

-- The shipped light Catppuccin theme maps to Latte and carries light mode.
write_state("catppuccin-latte", "light", "#eff1f5", "#dce0e8", "#4c4f69")
adapter.reload()
assert(adapter.palette().colorscheme == "catppuccin-latte")
assert(vim.g.last_colorscheme == "catppuccin-latte")
assert(vim.o.background == "light")

-- Unknown Omarchy themes use the staged palette and Rose Pine's matching variant.
write_state("flexoki-light", "light", "#fffcf0", "#f2f0e5", "#100f0f")
adapter.apply()
assert(adapter.palette().colorscheme == nil)
assert(rose_calls[#rose_calls].variant == "dawn")
assert(rose_calls[#rose_calls].palette.dawn.base == "#fffcf0")

-- Invalid and missing generated state never impose a private static palette.
vim.fn.writefile({ "return { schema_version = 99 }" }, palette_file)
assert(adapter.palette() == nil)
local palettes_before_missing_state = #rose_calls
assert(adapter.apply() == false)
assert(#rose_calls == palettes_before_missing_state)
vim.fn.delete(palette_file)
assert(adapter.palette() == nil)
assert(adapter.apply() == false)

-- A catalog mapping whose plugin cannot load falls back to Rose Pine.
write_state("catppuccin", "dark", "#1e1e2e", "#313244", "#cdd6f4")
vim.g.TEST_NATIVE_UNAVAILABLE = true
adapter.apply()
assert(vim.g.last_colorscheme == "rose-pine-main")
assert(rose_calls[#rose_calls].variant == "main")
vim.g.TEST_NATIVE_UNAVAILABLE = false

-- Execute the actual consumer configs and assert both refresh from the new
-- source after adapter application/theme changes.
local lualine_spec = dofile(repo .. "/env/.config/nvim/lua/plugins/lualine.lua")
lualine_spec.config()
local noice_spec = dofile(repo .. "/env/.config/nvim/lua/plugins/noice.lua")
noice_spec.config()
local before_lualine, before_notify = #lualine_calls, #notify_calls
write_state("catppuccin-latte", "light", "#eff1f5", "#dce0e8", "#4c4f69")
adapter.reload()
assert(#lualine_calls > before_lualine, "Lualine did not refresh on adapter event")
assert(#notify_calls > before_notify, "notify background did not refresh on adapter event")
assert(notify_calls[#notify_calls].background_colour == "#eff1f5")
assert(lualine_calls[#lualine_calls].options.theme.normal.c.bg == "#dce0e8")
assert(vim.api.nvim_get_hl(0, { name = "StatusLine" }).bg == tonumber("dce0e8", 16))
assert(applied_events >= 5, "adapter did not signal theme applications")

print("actual Neovim adapter, native/fallback mapping, and Lualine/notify checks passed")
LUA

DOTFILES_REPO="$repo" TEST_RUNTIME="$tmp/runtime" \
HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
nvim --headless --clean -i NONE -u NONE -l "$tmp/check.lua"
