return {
	"NeogitOrg/neogit",
	dependencies = {
		"nvim-lua/plenary.nvim",
		"sindrets/diffview.nvim",
		"nvim-telescope/telescope.nvim",
	},
	cmd = "Neogit",
	config = function()
		require("neogit").setup({
			kind = "split_above",
			commit_editor = {
				kind = "split",
			},
			preview_buffer = {
				kind = "split",
			},
			popup = {
				kind = "split",
			},
			integrations = {
				diffview = true,
				telescope = true,
			},
		})
	end,
}
