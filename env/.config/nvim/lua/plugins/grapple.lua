return {
	"cbochs/grapple.nvim",
	dependencies = {
		{ "echasnovski/mini.icons", lazy = true },
	},
	config = function()
		local strings = require("utils.strings")
		require("grapple").setup({
			scope = "git",
			icons = true,
			status = false,
			tag_title = function()
				local cwd = vim.fn.getcwd()
				local dir_name = vim.fn.fnamemodify(cwd, ":t")
				return strings.titlecase(dir_name)
			end,
			win_opts = {
				footer = "",
			},
		})
	end,
}
