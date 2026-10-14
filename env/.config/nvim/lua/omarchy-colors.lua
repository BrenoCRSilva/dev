local M = {}

local COLORS = {
	catppuccin = { dark = "catppuccin-mocha", light = "catppuccin-latte" },
	["catppuccin-latte"] = { light = "catppuccin-latte" },
	gruvbox = { dark = "gruvbox" },
	kanagawa = { dark = "kanagawa-wave", light = "kanagawa-lotus" },
	nord = { dark = "nord" },
	["rose-pine"] = { dark = "rose-pine-main", light = "rose-pine-dawn" },
	["tokyo-night"] = { dark = "tokyonight-night", light = "tokyonight-day" },
}

local REQUIRED = {
	"background", "surface", "foreground", "subtle", "muted",
	"red", "yellow", "green", "cyan", "blue", "magenta",
}

function M.read()
	local state = vim.env.XDG_STATE_HOME
	if not state or state == "" then
		state = vim.fn.expand("~/.local/state")
	end

	local root = state .. "/omarchy/current"
	local loader = loadfile(root .. "/theme/nvim-palette.lua")
	if not loader then
		return nil
	end

	local ok, palette = pcall(loader)
	if not ok or type(palette) ~= "table" or palette.schema_version ~= 1 then
		return nil
	end
	for _, key in ipairs(REQUIRED) do
		if type(palette[key]) ~= "string" or not palette[key]:match("^#%x%x%x%x%x%x$") then
			return nil
		end
	end
	if palette.mode ~= "dark" and palette.mode ~= "light" then
		return nil
	end

	local ok_name, names = pcall(vim.fn.readfile, root .. "/theme.name")
	local theme_name = ok_name and names[1] or nil
	if type(theme_name) == "string" and theme_name:match("^[%w][%w%-]*$") then
		palette.theme_name = theme_name
		local choices = COLORS[theme_name]
		palette.colorscheme = choices and choices[palette.mode] or nil
	end
	palette.base = palette.background
	palette.overlay = palette.surface
	palette.text = palette.foreground
	return palette
end

return M
