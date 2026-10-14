return {
	"ThePrimeagen/99",
	config = function()
		local _99 = require("99")

		local cwd = vim.uv.cwd()
		local basename = vim.fs.basename(cwd)
		_99.setup({
			logger = {
				level = _99.DEBUG,
				path = "/tmp/" .. basename .. ".99.debug",
				print_on_error = true,
			},

			completion = {
				files = {
					-- enabled = true,
					-- max_file_size = 102400,     -- bytes, skip files larger than this
					-- max_files = 5000,            -- cap on total discovered files
					-- exclude = { ".env", ".env.*", "node_modules", ".git", ... },
				},
			},

			md_files = {
				"agents.md",
			},
		})
	end,
}
