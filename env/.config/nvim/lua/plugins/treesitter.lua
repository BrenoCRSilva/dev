return {
	{
		"nvim-treesitter/nvim-treesitter",
		branch = "main",
		lazy = false,
		build = ":TSUpdate",
		config = function()
			-- Parsers install into site/ on first open (brenocrs/highlight.lua); the core list is
			-- installed at startup.
			require("brenocrs.highlight").setup()
		end,
	},
}
