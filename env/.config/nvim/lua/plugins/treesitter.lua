return {
	{
		"nvim-treesitter/nvim-treesitter",
		branch = "main",
		lazy = false,
		build = ":TSUpdate",
		config = function()
			local ts = require("nvim-treesitter")
			ts.install({ "c", "go", "lua", "vim", "vimdoc", "query", "markdown", "markdown_inline" })

			-- Highlighting is Neovim's own; start it per buffer and install a missing
			-- parser on first use (replaces master's `auto_install`).
			vim.api.nvim_create_autocmd("FileType", {
				group = vim.api.nvim_create_augroup("brenocrs-treesitter", { clear = true }),
				callback = function(args)
					local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype)
					if not lang then
						return
					end
					if vim.treesitter.language.add(lang) then
						pcall(vim.treesitter.start, args.buf, lang)
						return
					end
					if not vim.tbl_contains(ts.get_available(), lang) then
						return
					end
					ts.install({ lang }):await(function(err)
						if err then
							return
						end
						vim.schedule(function()
							if vim.api.nvim_buf_is_valid(args.buf) then
								pcall(vim.treesitter.start, args.buf, lang)
							end
						end)
					end)
				end,
			})
		end,
	},
}
