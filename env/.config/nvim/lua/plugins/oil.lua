return {
	"stevearc/oil.nvim",
	dependencies = { { "echasnovski/mini.icons", opts = {} } },
	lazy = false,
	config = function()
		require("oil").setup({
			columns = { "icon" },
			default_file_explorer = true,
			view_options = {
				show_hidden = false,
			},
			-- <C-t> is oil's select_tab; no tabs here.
			keymaps = { ["<C-t>"] = false },
		})
	end,
}
