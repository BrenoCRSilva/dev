return {
	"folke/noice.nvim",
	event = "VeryLazy",
	opts = {},
	dependencies = {
		"MunifTanjim/nui.nvim",
		"rcarriga/nvim-notify",
	},
	config = function()
		local function setup_notify_background()
			require("notify").setup({
				background_colour = require("pontuarch").palette().background,
			})
		end
		setup_notify_background()
		vim.api.nvim_create_autocmd("User", {
			pattern = "PontuarchThemeApplied",
			callback = setup_notify_background,
		})
		vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_notify_background })
		require("noice").setup({
			views = {
				cmdline_popup = {
					position = {
						row = "40%",
						col = "50%",
					},
					win_options = {
						winblend = 20,
					},
				},
			},
			lsp = {
				hover = {
					enabled = true,
					opts = {
						border = {
							style = "single",
						},
						size = {
							max_width = 80,
							max_height = 20,
						},
					},
				},
				signature = {
					enabled = false,
				},
				override = {
					["vim.lsp.util.convert_input_to_markdown_lines"] = true,
					["vim.lsp.util.stylize_markdown"] = true,
					["cmp.entry.get_documentation"] = true,
				},
			},
			presets = {
				bottom_search = true,
				command_palette = true,
				long_message_to_split = true,
				inc_rename = true,
				lsp_doc_border = false,
			},
		})
		vim.notify = require("notify")
	end,
}
