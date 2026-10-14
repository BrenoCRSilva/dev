return {
	"nvim-telescope/telescope.nvim",
	tag = "0.1.8",

	dependencies = {
		"echasnovski/mini.icons",
		"nvim-lua/plenary.nvim",
		{ "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
	},
	config = function()
		local actions = require("telescope.actions")
		local trouble = require("trouble")
		local function send_to_trouble_quickfix(prompt_bufnr)
			actions.send_to_qflist(prompt_bufnr)
			if trouble.is_open() then
				trouble.close()
			end
			trouble.open("quickfix")
		end
		require("telescope").setup({
			defaults = {
				mappings = {
					i = { ["<c-i>"] = send_to_trouble_quickfix },
					n = { ["<c-i>"] = send_to_trouble_quickfix },
				},
				sorting_strategy = "ascending",
				layout_config = {
					prompt_position = "top",
				},
			},
			extensions = {
				fzf = {},
			},
		})
	end,
}
