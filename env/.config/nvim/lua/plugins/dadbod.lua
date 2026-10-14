return {
	"kristijanhusak/vim-dadbod-ui",
	dependencies = {
		{ "tpope/vim-dadbod", lazy = true },
		{ "kristijanhusak/vim-dadbod-completion", ft = { "sql", "mysql", "plsql", "mongosh" }, lazy = true },
	},
	cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer" },
	init = function()
		vim.g.db_ui_use_nerd_fonts = 1
		-- Saved connections (or use :DBUIAddConnection / the persisted store).
		-- mongosh must be on PATH for the mongodb:// adapter.
		-- URLs come from the environment so no secrets live in the repo.
		-- e.g. export TALQUI_MONGO_URI="mongodb+srv://user:pass@host/dbname?appName=breno"
		-- NB: vim.g.dbs returns a copy, so build the table then assign it once.
		local dbs = {}
		local talqui = os.getenv("TALQUI_MONGO_URI")
		if talqui and talqui ~= "" then
			dbs.talqui = talqui
		end
		vim.g.dbs = dbs
	end,
	keys = {
		{ "<leader>db", "<cmd>DBUIToggle<cr>", desc = "Dadbod UI toggle" },
		{ "<leader>df", "<cmd>DBUIFindBuffer<cr>", desc = "Dadbod find buffer" },
	},
}
