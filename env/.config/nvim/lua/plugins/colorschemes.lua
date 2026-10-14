-- Native colorschemes available to the Omarchy theme adapter. Declared lazy;
-- lua/omarchy-theme.lua loads only the matching plugin on a supported theme switch.
-- rose-pine remains the palette-driven fallback in its own spec.
return {
	{ "folke/tokyonight.nvim", lazy = true },
	{ "ellisonleao/gruvbox.nvim", lazy = true },
	{ "sainnhe/sonokai", lazy = true },
	{ "Mofiqul/dracula.nvim", lazy = true },
	{ "Mofiqul/vscode.nvim", lazy = true },
	{ "navarasu/onedark.nvim", lazy = true },
	{ "shaunsingh/nord.nvim", lazy = true },
	{ "projekt0n/github-nvim-theme", lazy = true },
	{ "rebelot/kanagawa.nvim", lazy = true },
	{ "catppuccin/nvim", name = "catppuccin", lazy = true },
}
