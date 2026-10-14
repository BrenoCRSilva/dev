return {
	"rose-pine/neovim",
	name = "rose-pine",
	priority = 1000,
	config = function()
		-- Rose Pine provides a palette-driven fallback for unsupported Omarchy
		-- themes; supported themes select an installed native colorscheme instead.
		require("pontuarch").apply()

		vim.api.nvim_create_user_command("PontuarchReload", function()
			require("pontuarch").reload()
		end, {})
	end,
}
