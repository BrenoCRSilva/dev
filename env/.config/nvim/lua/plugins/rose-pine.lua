return {
	"rose-pine/neovim",
	name = "rose-pine",
	priority = 1000,
	config = function()
		-- Rose Pine uses the active Omarchy palette only when a theme is staged;
		-- otherwise leave the editor's current colorscheme untouched.
		require("omarchy-theme").apply()

		vim.api.nvim_create_user_command("OmarchyThemeReload", function()
			require("omarchy-theme").reload()
		end, {})
	end,
}
