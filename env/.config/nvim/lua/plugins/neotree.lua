return {
	{
		"nvim-neo-tree/neo-tree.nvim",
		branch = "v3.x",
		dependencies = {
			"nvim-lua/plenary.nvim",
			"MunifTanjim/nui.nvim",
			"nvim-tree/nvim-web-devicons",
		},
		config = function()
			require("neo-tree").setup({
				source_selector = {
					winbar = false,
					statusline = false,
				},
				open_files_do_not_replace_types = { "terminal", "trouble", "qf" },
				window = {
					position = "left",
					mappings = { t = false }, -- neo-tree's t opens a new tab
				},
				filesystem = {
					filtered_items = {
						visible = true, -- Show hidden files by default
						hide_dotfiles = false,
						hide_gitignored = false,
					},
					follow_current_file = {
						enabled = true,
					},
				},
				default_component_configs = {
					icon = {
						folder_closed = "",
						folder_open = "",
						folder_empty = "",
						folder_empty_open = "",
					},
					indent = {
						with_expanders = true,
						expander_collapsed = "",
						expander_expanded = "",
					},
				},
			})

			vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
				pattern = "neo-tree",
				callback = function()
					local function apply_neotree_window()
						if vim.bo.filetype ~= "neo-tree" then
							return
						end

						vim.opt_local.statusline = "%#NeoTreeTransparentStatus#%="
						vim.opt_local.winbar = ""
						vim.opt_local.winfixwidth = true
						vim.opt_local.winhighlight = table.concat({
							"StatusLine:NeoTreeTransparentStatus",
							"StatusLineNC:NeoTreeTransparentStatus",
							"lualine_transparent:NeoTreeTransparentStatus",
							"lualine_c_normal:NeoTreeTransparentStatus",
							"lualine_c_inactive:NeoTreeTransparentStatus",
						}, ",")
					end

					apply_neotree_window()
					vim.schedule(apply_neotree_window)
					vim.defer_fn(apply_neotree_window, 100)
				end,
			})
		end,
	},
}
