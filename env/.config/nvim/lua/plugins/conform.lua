return {
	"stevearc/conform.nvim",
	event = { "BufReadPre", "BufNewFile" },
	config = function()
		local conform = require("conform")
		local util = require("conform.util")

		local js_formatters = { "eslint_d", "prettier" }

		conform.setup({
			formatters_by_ft = {
				lua = { "stylua" },
				go = { "gofumpt", "goimports", "golines" },
				javascript = js_formatters,
				javascriptreact = js_formatters,
				typescript = js_formatters,
				typescriptreact = js_formatters,
				vue = js_formatters,
				json = { "prettier" },
				yaml = { "prettier" },
				markdown = { "prettier" },
				python = { "black" },
			},
			formatters = {
				eslint_d = {
					cwd = util.root_file({
						"eslint.config.js",
						"eslint.config.mjs",
						"eslint.config.cjs",
						".eslintrc",
						".eslintrc.js",
						".eslintrc.cjs",
						".eslintrc.json",
						"package.json",
						".git",
					}),
				},
			},
			format_on_save = function(bufnr)
				local ft = vim.bo[bufnr].filetype
				local no_lsp_fallback =
					{ javascript = true, javascriptreact = true, typescript = true, typescriptreact = true, vue = true }
				return {
					lsp_format = no_lsp_fallback[ft] and "never" or "fallback",
					timeout_ms = 500,
				}
			end,
		})
	end,
}
