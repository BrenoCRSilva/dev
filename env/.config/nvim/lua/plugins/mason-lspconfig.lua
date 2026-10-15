return {
	"williamboman/mason-lspconfig.nvim",
	dependencies = {
		{
			"williamboman/mason.nvim",
			opts = {
				ui = {
					icons = {
						package_installed = "✓",
						package_pending = "➜",
						package_uninstalled = "✗",
					},
				},
			},
		},
		"neovim/nvim-lspconfig",
		"WhoIsSethDaniel/mason-tool-installer",
		"nvim-telescope/telescope.nvim",
	},
	config = function()
		vim.diagnostic.config({
			severity_sort = true,
			virtual_text = {
				virt_text_pos = "eol",
			},
			signs = {
				text = {
					[vim.diagnostic.severity.ERROR] = " ",
					[vim.diagnostic.severity.WARN] = " ",
					[vim.diagnostic.severity.HINT] = "󰠠 ",
					[vim.diagnostic.severity.INFO] = " ",
				},
			},
		})

		local on_attach = function(client, bufnr)
			vim.bo[bufnr].omnifunc = "v:lua.vim.lsp.omnifunc"

			local telescope = require("telescope.builtin")
			local map = vim.keymap.set
			local opts = { buffer = bufnr }

			map("n", "<leader>fr", telescope.lsp_references, opts)
			map("n", "<leader>fi", telescope.lsp_implementations, opts)
			map("n", "<leader>rn", vim.lsp.buf.rename, opts)
			map("n", "gD", vim.lsp.buf.declaration, opts)
			map("n", "gd", require("brenocrs.lsp-definition").goto_definition, opts)
			map("n", "K", vim.lsp.buf.hover, opts)
		end

		vim.lsp.config("gopls", {
			on_attach = on_attach,
		})

		vim.lsp.config("pyright", {
			on_attach = on_attach,
			settings = {
				python = {
					pythonPath = "./venv/bin/python",
				},
			},
		})

		vim.lsp.config("lua_ls", {
			on_attach = on_attach,
			settings = {
				Lua = {
					runtime = {
						version = "LuaJIT",
					},
					diagnostics = {
						globals = { "vim" },
					},
				},
			},
		})

		-- Substitui o vim.lsp.con (typo) e adiciona vue_ls
		vim.lsp.config("ts_ls", {
			on_attach = on_attach,
			init_options = {
				plugins = {
					{
						name = "@vue/typescript-plugin",
						location = vim.fn.stdpath("data")
							.. "/mason/packages/vue-language-server/node_modules/@vue/typescript-plugin",
						languages = { "vue" },
					},
				},
			},
			filetypes = { "typescript", "javascript", "javascriptreact", "typescriptreact", "vue" },
			-- Cap the tsserver heap (MB); large monorepos otherwise grow it without limit.
			settings = {
				typescript = { tsserver = { maxTsServerMemory = 3072 } },
			},
		})

		vim.lsp.config("vue_ls", {
			on_attach = on_attach,
		})

		local qmlls = vim.fn.executable("/usr/lib/qt6/bin/qmlls") == 1 and "/usr/lib/qt6/bin/qmlls"
			or vim.fn.exepath("qmlls")
		if qmlls ~= "" then
			vim.lsp.config("qmlls", {
				on_attach = on_attach,
				-- Prefer the system Qt server (its runtime libraries are installed).
				-- Mason's copy currently fails to load libodbc.so.2 on this host.
				cmd = { qmlls, "-E" },
			})
		else
			vim.notify("qmlls not found; QML language support is unavailable", vim.log.levels.WARN)
		end

		local stylua = vim.fn.exepath("stylua")
		if stylua ~= "" then
			vim.lsp.config("stylua", {
				cmd = { stylua, "--lsp" },
				filetypes = { "lua" },
				root_dir = function(bufnr, on_dir)
					local name = vim.api.nvim_buf_get_name(bufnr)
					local root = vim.fs.root(bufnr, { "stylua.toml", ".stylua.toml", ".git" })
					on_dir(root or vim.fs.dirname(name))
				end,
				on_attach = on_attach,
			})
			vim.lsp.enable("stylua")
		end

		vim.lsp.config("bashls", {
			cmd = { "bash-language-server", "start" },
			filetypes = { "bash", "sh" },
		})

		vim.lsp.config("rust_analyzer", {
			on_attach = on_attach,
			settings = {
				["rust-analyzer"] = {
					check = {
						command = "clippy",
					},
					inlayHints = {
						enable = true,
						parameterHints = true,
						typeHints = true,
					},
					cargo = {
						allFeatures = true,
					},
				},
			},
		})
		require("mason-tool-installer").setup({
			run_on_start = false,
			auto_update = false,

			ensure_installed = {
				{ "bash-language-server", auto_update = true },
				"shellcheck",
				"golangci-lint",
				"goimports",
				"gofumpt",
				"black",
				"golines",
				"gomodifytags",
				"gotests",
				"prettier",
				"eslint_d",
				"stylua",
				"luacheck",
			},
		})

		local servers = {
			"lua_ls",
			"pyright",
			"gopls",
			"ts_ls",
			"vue_ls",
			"rust_analyzer",
		}
		if qmlls ~= "" then
			table.insert(servers, "qmlls")
		end
		require("mason-lspconfig").setup({
			automatic_enable = servers,
			ensure_installed = {
				"lua_ls",
				"pyright",
				"gopls",
				"ts_ls",
				"vue_ls",
				"rust_analyzer",
			},
		})

		-- Stop servers idle for 10 minutes; they restart when a buffer is entered.
		require("brenocrs.lsp-idle").setup()
	end,
}
