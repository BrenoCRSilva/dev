return {
	{
		"echasnovski/mini.icons",
		version = false,
		priority = 1000,
		lazy = true,
		config = function()
			require("mini.icons").setup()
			require("mini.icons").mock_nvim_web_devicons()
		end,
	},
}
