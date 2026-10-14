-- Personal theme adapter. On Omarchy, the theme template is the sole palette
-- producer; this module reads its generated current-theme output at startup
-- and on the single Omarchy theme-set hook signal.
--
-- Omarchy owns the current theme slug and generated palette. Map supported
-- slugs to colorschemes already present in the personal Lazy catalog. Unknown
-- themes keep their palette and use Rose Pine as a compatible fallback.
local M = {}

-- Map a theme's `nvim_colorscheme` (e.g. "tokyonight-night", "github_dark_default")
-- to the lazy.nvim plugin that provides it, so the bridge can load that plugin on
-- demand before `:colorscheme`. Matched by prefix.
local PLUGIN_FOR = {
	["tokyonight"] = "tokyonight.nvim",
	["gruvbox"] = "gruvbox.nvim",
	["sonokai"] = "sonokai",
	["dracula"] = "dracula.nvim",
	["vscode"] = "vscode.nvim",
	["onedark"] = "onedark.nvim",
	["nord"] = "nord.nvim",
	["github"] = "github-nvim-theme",
	["kanagawa"] = "kanagawa.nvim",
	["rose-pine"] = "rose-pine",
	["catppuccin"] = "catppuccin",
}

local THEME_COLORSCHEMES = {
	catppuccin = { dark = "catppuccin-mocha", light = "catppuccin-latte" },
	["catppuccin-latte"] = { light = "catppuccin-latte" },
	gruvbox = { dark = "gruvbox" },
	kanagawa = { dark = "kanagawa-wave", light = "kanagawa-lotus" },
	nord = { dark = "nord" },
	["rose-pine"] = { dark = "rose-pine-main", light = "rose-pine-dawn" },
	["tokyo-night"] = { dark = "tokyonight-night", light = "tokyonight-day" },
}

local function load_colorscheme_plugin(cs)
	for prefix, plugin in pairs(PLUGIN_FOR) do
		if cs:sub(1, #prefix) == prefix then
			pcall(function()
				require("lazy").load({ plugins = { plugin } })
			end)
			return
		end
	end
end

-- Static fallback for hosts without Omarchy or before its first theme set.
local FALLBACK = {
	mode = "dark",
	background = "#191724",
	surface = "#26233a",
	foreground = "#e0def4",
	subtle = "#908caa",
	muted = "#6e6a86",
	red = "#eb6f92",
	yellow = "#f6c177",
	cyan = "#9ccfd8",
	green = "#31748f",
	blue = "#9ccfd8",
	magenta = "#c4a7e7",
	base = "#191724",
	overlay = "#26233a",
	text = "#e0def4",
}

local function hex(n)
	return type(n) == "number" and string.format("#%06x", n) or nil
end

-- Groups whose background we clear so Neovim is transparent — the terminal
-- (ghostty, with the theme bg + opacity) shows through instead of nvim painting
-- an opaque background. Covers the editor, statusline, floats (LSP hover /
-- diagnostics / signature help / grapple / which-key), the message + command
-- line area, the wildmenu/completion popup, and Telescope's panes. NOTE the
-- *Sel/*Selection groups are deliberately excluded so the selection highlight
-- stays visible.
local TRANSPARENT_GROUPS = {
	-- editor
	"Normal", "NormalNC", "EndOfBuffer", "SignColumn", "LineNr", "CursorLineNr",
	"FoldColumn", "WinSeparator",
	-- statusline / tabline
	"StatusLine", "StatusLineNC", "TabLineFill",
	-- floats (LSP popups, diagnostics, signature help, grapple, which-key)
	"NormalFloat", "FloatBorder", "FloatTitle", "FloatFooter",
	-- messages / command line
	"MsgArea", "MsgSeparator",
	-- wildmenu / completion popup (the ":" command-line completion menu)
	"Pmenu", "PmenuSbar", "PmenuThumb", "PmenuKind", "PmenuExtra",
	-- telescope
	"TelescopeNormal", "TelescopeBorder",
	"TelescopePromptNormal", "TelescopePromptBorder",
	"TelescopeResultsNormal", "TelescopeResultsBorder",
	"TelescopePreviewNormal", "TelescopePreviewBorder",
	"TelescopePromptTitle", "TelescopeResultsTitle", "TelescopePreviewTitle",
}

-- fg of a highlight group, falling back to `fallback` when unset.
local function group_fg(name, fallback)
	local g = vim.api.nvim_get_hl(0, { name = name, link = false })
	return hex(g.fg) or fallback
end

-- Run after ANY colorscheme (native or fallback): make nvim transparent, force
-- folds to the scheme's String color, and reset the grapple menu to the active
-- scheme (always — so it never keeps a stale palette from a previous colorscheme).
local function post_apply(p)
	local hl = function(g, o) vim.api.nvim_set_hl(0, g, o) end

	for _, g in ipairs(TRANSPARENT_GROUPS) do
		local c = vim.api.nvim_get_hl(0, { name = g, link = false })
		c.bg = nil
		c.ctermbg = nil
		hl(g, c)
	end

	-- Folds always render in the active scheme's String color.
	local sfg = group_fg("String", p.green or "#9ece6a")
	hl("Folded", { fg = sfg, bg = "NONE", bold = true })
	hl("FoldColumn", { fg = sfg, bg = "NONE" })
	hl("UfoFoldedFg", { fg = sfg, bold = true })
	hl("UfoFoldedBg", { bg = "NONE" })

	-- Grapple menu follows the active scheme (reset on every apply so switching
	-- native→native/fallback never leaves it tinted by the previous palette).
	local border = group_fg("FloatBorder", p.muted)
	local title = group_fg("Title", p.yellow or p.red)
	hl("GrappleNormal", { bg = "NONE" })
	hl("GrappleBorder", { fg = border, bg = "NONE" })
	hl("GrappleTitle", { fg = title, bg = "NONE", bold = true })
	hl("GrappleFooter", { fg = p.muted, bg = "NONE" })
end

-- Read the generated palette fresh (bypassing the module cache so reloads pick
-- up the new colors).
function M.palette()
	local state = vim.env.XDG_STATE_HOME
	if not state or state == "" then
		state = vim.fn.expand("~/.local/state")
	end
	local path = state .. "/omarchy/current/theme/nvim-palette.lua"
	local theme_path = state .. "/omarchy/current/theme.name"
	local loader = loadfile(path)
	if loader then
		local ok, p = pcall(loader)
		if ok and type(p) == "table" and p.schema_version == 1 then
			local valid = true
			for _, key in ipairs({ "background", "surface", "foreground", "subtle", "muted", "red", "yellow", "green", "cyan", "blue", "magenta" }) do
				if type(p[key]) ~= "string" or not p[key]:match("^#%x%x%x%x%x%x$") then
					valid = false
					break
				end
			end
			valid = valid and (p.mode == "dark" or p.mode == "light")
			if valid then
				local theme_name = vim.fn.readfile(theme_path)[1]
				if type(theme_name) == "string" and theme_name:match("^[%w][%w%-]*$") then
					p.theme_name = theme_name
					local choices = THEME_COLORSCHEMES[theme_name]
					p.colorscheme = choices and choices[p.mode] or nil
				end
				p.base, p.overlay, p.text = p.background, p.surface, p.foreground
				return p
			end
		end
	end
	return FALLBACK
end

-- Build, apply, and overlay the active palette onto rose-pine.
function M.apply()
	local p = M.palette()
	vim.o.background = p.mode

	-- Path 1: native colorscheme declared by the theme → load its plugin (lazy) and
	-- apply. A purpose-built theme always looks better than re-tinting a fallback.
	if type(p.colorscheme) == "string" and p.colorscheme ~= "" then
		load_colorscheme_plugin(p.colorscheme)
		local ok = pcall(vim.cmd.colorscheme, p.colorscheme)
		if ok then
			post_apply(p)
			vim.api.nvim_exec_autocmds("User", { pattern = "PontuarchThemeApplied", modeline = false })
			return
		end
	end

	-- Path 2: no native theme (e.g. an autocolor/wallpaper palette) → drive
	-- rose-pine from the generated palette. rose-pine's slot names map to our ANSI
	-- accents: love=red, gold=yellow, rose=cyan, pine=green, foam=blue, iris=magenta.
	local hl = function(group, opts)
		vim.api.nvim_set_hl(0, group, opts)
	end
	local variant = p.mode == "light" and "dawn" or "main"

	require("rose-pine").setup({
		styles = { transparency = true },
		variant = variant,
		palette = {
			[variant] = {
				base = p.base,
				surface = p.overlay,
				overlay = p.overlay,
				muted = p.muted,
				subtle = p.subtle,
				text = p.text,
				love = p.red,
				gold = p.yellow,
				rose = p.cyan,
				pine = p.green,
				foam = p.blue,
				iris = p.magenta,
				highlight_low = p.overlay,
				highlight_med = p.subtle,
				highlight_high = p.muted,
			},
		},
	})
	vim.cmd("colorscheme rose-pine")

	-- Personal plugin overrides (fallback path only), palette-driven.
	hl("@function.builtin", { fg = p.red })
	hl("@type.builtin", { fg = p.blue, bold = true })
	hl("Visual", { bg = p.overlay })
	hl("AuxPaneNormal", { bg = "NONE" })
	hl("AuxPaneSeparator", { fg = p.muted, bg = "NONE" })
	hl("NeoTreeTransparentStatus", { bg = "NONE" })
	hl("NeoTreeStatusLine", { bg = "NONE" })
	hl("NeoTreeStatusLineNC", { bg = "NONE" })
	hl("HeaderA", { fg = p.subtle })
	hl("FooterA", { fg = p.muted })

	-- Transparency + folds-as-string + grapple (shared with the native path).
	post_apply(p)
	vim.api.nvim_exec_autocmds("User", { pattern = "PontuarchThemeApplied", modeline = false })
end

-- Re-read the staged Omarchy palette and re-apply. Called by the user
-- theme-set hook over existing nvim sockets; also exposed as :PontuarchReload.
function M.reload()
	M.apply()
end

return M
