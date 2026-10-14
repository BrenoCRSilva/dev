return {
	"folke/trouble.nvim",
	config = function()
		local trouble = require("trouble")
		local pane_style = require("brenocrs.pane-style")
		local pane_window = {
			type = "split",
			position = "bottom",
			relative = "win",
			wo = {
				statusline = " ",
				winbar = "%#AuxPaneSeparator#%{repeat('─', winwidth(0))}",
				winhighlight = pane_style.winhighlight,
			},
		}

		trouble.setup({
			modes = {
				buffer_diagnostics = {
					mode = "diagnostics",
					auto_open = false,
					auto_close = true,
					focus = false,
					group = false,
					indent_lines = false,
					win = pane_window,
					filter = { buf = 0 },
					keys = {
						["<cr>"] = "jump",
						["<esc>"] = "close",
					},
				},
				quickfix = {
					auto_open = false,
					auto_close = true,
					focus = false,
					group = false,
					indent_lines = false,
					win = pane_window,
					keys = {
						["<cr>"] = "jump",
						["<esc>"] = "close",
					},
				},
				diagnostics = {
					auto_open = false,
					auto_close = true,
					focus = false,
					group = false,
					indent_lines = false,
					win = pane_window,
					keys = {
						["<cr>"] = "jump",
						["<esc>"] = "close",
					},
				},
			},
		})
	end,
}
