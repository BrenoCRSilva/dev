return {
	"nvim-lualine/lualine.nvim",
	dependencies = { "echasnovski/mini.icons", "rose-pine" },
	config = function()
		-- Read the same staged Omarchy palette used by the colorscheme adapter.
		local function pal()
			return require("omarchy-theme").palette()
		end
		-- Use the staged Omarchy surface, or preserve the current colorscheme's
		-- statusline background when no Omarchy palette exists.
		local function statusline_base()
			local palette = pal()
			if palette then
				return palette.overlay
			end
			return vim.api.nvim_get_hl(0, { name = "StatusLine", link = false }).bg or "NONE"
		end

		local function apply_statusline_bg()
			local base = statusline_base()
			for _, group in ipairs({ "StatusLine", "StatusLineNC" }) do
				local hl = vim.api.nvim_get_hl(0, { name = group })
				hl.bg = base
				vim.api.nvim_set_hl(0, group, hl)
			end
			vim.api.nvim_set_hl(0, "lualine_transparent", { bg = "NONE" })
			vim.api.nvim_set_hl(0, "NeoTreeStatusLine", { bg = "NONE" })
			vim.api.nvim_set_hl(0, "NeoTreeStatusLineNC", { bg = "NONE" })

			for _, group in ipairs({
				"lualine_c_normal",
				"lualine_x_normal",
				"lualine_c_insert",
				"lualine_x_insert",
				"lualine_c_visual",
				"lualine_x_visual",
				"lualine_c_replace",
				"lualine_x_replace",
				"lualine_c_command",
				"lualine_x_command",
				"lualine_c_terminal",
				"lualine_x_terminal",
				"lualine_c_inactive",
				"lualine_x_inactive",
			}) do
				local hl = vim.api.nvim_get_hl(0, { name = group })
				if next(hl) ~= nil then
					hl.bg = base
					vim.api.nvim_set_hl(0, group, hl)
				end
			end
		end

		local function apply_neotree_statusline()
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				local buf = vim.api.nvim_win_get_buf(win)
				if vim.bo[buf].filetype == "neo-tree" then
					vim.api.nvim_set_option_value("statusline", "%#lualine_transparent#%=", { win = win })
					vim.api.nvim_set_option_value("winbar", "", { win = win })
				end
			end
		end

		-- Build lualine's theme from the auto theme (derived from the active
		-- colorscheme's highlights). Cache-busted so it re-derives after a theme
		-- switch instead of returning the snapshot taken at startup.
		local function build_theme()
			package.loaded["lualine.themes.auto"] = nil
			local theme = vim.deepcopy(require("lualine.themes.auto"))
			local base = statusline_base()
			for _, mode in ipairs({ "normal", "insert", "visual", "replace", "command", "terminal", "inactive" }) do
				if theme[mode] and theme[mode].c then
					theme[mode].c.bg = base
					theme[mode].x = vim.deepcopy(theme[mode].c)
					theme[mode].y = vim.deepcopy(theme[mode].b or theme[mode].c)
					theme[mode].z = vim.deepcopy(theme[mode].a or theme[mode].b or theme[mode].c)
				end
			end
			return theme
		end

		local filename = {
			"filename",
			path = 1,
			fmt = function(str)
				if str == "[No Name]" then
					return ""
				end

				local result = string.gsub(str, "^oil:///", "")
				result = string.gsub(result, "^home", "~")
				return result
			end,
		}

		-- (Re)apply lualine with a freshly-built, theme-following palette. Safe to
		-- call again on ColorScheme — lualine supports re-setup.
		local function setup_lualine()
			require("lualine").setup({
				options = {
					component_separators = { left = "", right = "" },
					section_separators = { left = "", right = "" },
					globalstatus = false,
					disabled_filetypes = {
						statusline = {
							"neo-tree",
							"qf",
							"trouble",
							"Trouble",
							"grapple",
							"NeogitStatus",
							"NeogitPopup",
							"NeogitCommitMessage",
							"NeogitCommitView",
							"NeogitDiffView",
							"NeogitLogView",
							"NeogitReflogView",
							"NeogitGitCommandHistory",
						},
					},
					theme = build_theme(),
				},
				sections = {
					lualine_a = { "mode" },
					lualine_b = { "grapple" },
					lualine_c = { filename },
					lualine_x = { "diagnostics" },
					lualine_y = { "progress" },
					lualine_z = { "location" },
				},
				inactive_sections = {
					lualine_a = {},
					lualine_b = {},
					lualine_c = { filename },
					lualine_x = {},
					lualine_y = {},
					lualine_z = {},
				},
			})
		end

		setup_lualine()
		apply_statusline_bg()
		vim.schedule(apply_statusline_bg)
		vim.defer_fn(apply_statusline_bg, 100)

		-- Theme switch: rebuild section colors from the new palette, then repaint
		-- the statusline bg. (The base colorscheme is re-applied by omarchy-theme.lua,
		-- which fires ColorScheme.)
		vim.api.nvim_create_autocmd("ColorScheme", {
			callback = function()
				setup_lualine()
				apply_statusline_bg()
				vim.schedule(apply_statusline_bg)
			end,
		})
		vim.api.nvim_create_autocmd("User", {
			pattern = "OmarchyThemeApplied",
			callback = function()
				setup_lualine()
				apply_statusline_bg()
				vim.schedule(apply_statusline_bg)
			end,
		})
		vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
			callback = apply_statusline_bg,
		})
		vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "FileType", "CursorMoved", "CursorMovedI" }, {
			callback = function()
				apply_neotree_statusline()
				vim.schedule(apply_neotree_statusline)
				vim.defer_fn(apply_neotree_statusline, 50)
			end,
		})
	end,
}
