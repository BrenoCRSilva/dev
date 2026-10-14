return {
	"folke/which-key.nvim",
	event = "VeryLazy",
	config = function()
		local wk = require("which-key")

		wk.setup({
			plugins = {
				marks = true,
				registers = true,
				spelling = {
					enabled = true,
					suggestions = 20,
				},
				presets = {
					operators = true,
					motions = true,
					text_objects = true,
					windows = true,
					nav = true,
					z = true,
					g = true,
				},
			},
			win = {
				border = "rounded",
			},
			delay = 1000,
		})

		wk.add({
			-- Normal mode mappings
			{ "$", desc = "Go to Last Non-blank" },
			{ "*", desc = "Go to First Non-blank" },
			{ "<C-d>", desc = "Scroll Down (Center)" },
			{ "<C-n>", desc = "Trouble Next Item" },
			{ "<C-p>", desc = "Trouble Previous Item" },
			{ "<C-u>", desc = "Scroll Up (Center)" },
			{ "K", desc = "Hover Documentation" },
			{ "gD", desc = "Go to Declaration" },
			{ "gd", desc = "Go to Definition" },

			-- Leader mappings
			{ "<leader>s", desc = "Save File" },
			{ "<leader>q", desc = "Save and quit / close panel" },
			{ "<leader>o", desc = "Open Oil" },
			{ "<leader>u", desc = "Toggle Undotree" },
			{ "<leader>a", desc = "Tag File" },
			{ "<leader>e", desc = "Toggle Tags Menu" },
			{ "<leader>p", desc = "Paste Without Yank" },
			{ "<leader>1", desc = "Select Tag 1" },
			{ "<leader>2", desc = "Select Tag 2" },
			{ "<leader>3", desc = "Select Tag 3" },
			{ "<leader>4", desc = "Select Tag 4" },
			{ "<leader>5", desc = "Select Tag 5" },

			-- Window group
			{ "<leader>w", group = "Window" },
			{ "<leader>wo", desc = "Close Other Windows" },
			{ "<leader>wl", desc = "Move to Right Window" },
			{ "<leader>wj", desc = "Move to Lower Window" },
			{ "<leader>wh", desc = "Move to Left Window" },
			{ "<leader>wk", desc = "Move to Upper Window" },

			-- Find group
			{ "<leader>f", group = "Find" },
			{ "<leader>ff", desc = "Find Files (CWD)" },
			{ "<leader>fa", desc = "Find All Files (Home)" },
			{ "<leader>fc", desc = "Find Config Files" },
			{ "<leader>fh", desc = "Find Help Tags" },
			{ "<leader>fb", desc = "Find Word in Buffer" },
			{ "<leader>fw", desc = "Find Word in Project" },
			{ "<leader>fW", desc = "Find WORD in Project" },
			{ "<leader>fg", desc = "Multi Grep" },
			{ "<leader>fr", desc = "LSP References" },
			{ "<leader>fi", desc = "LSP Implementations" },

			-- Git group
			{ "<leader>g", group = "Git" },
			{ "<leader>gm", desc = "Neogit" },
			{ "<leader>gd", desc = "Review uncommitted changes" },
			{ "<leader>gr", desc = "Review branch (vs main/master)" },
			{ "<leader>gh", desc = "File history" },
			{ "<leader>gH", desc = "Repository history" },
			{ "<leader>gq", desc = "Close diffview" },
			{ "<leader>gb", desc = "Branches (picker)" },
			{ "<leader>gB", desc = "Branches (Neogit popup)" },
			{ "<leader>gD", desc = "Delete Merged Branches" },
			{ "<leader>gP", desc = "Pull Rebase" },
			{ "<leader>gp", desc = "Push" },
			{ "<leader>go", desc = "Push Set Upstream" },

			-- Trouble/Tags group
			{ "<leader>t", group = "Trouble/Tags" },
			{ "<leader>tt", desc = "Toggle Diagnostics" },
			{ "<leader>th", desc = "Toggle Buffer Diagnostics" },
			{ "<leader>tf", desc = "Toggle Quickfix" },
			{ "<leader>tg", desc = "Add Go Tags" },
			{ "<leader>tr", desc = "Remove Go Tags" },

			-- Folds group
			{ "<leader>d", group = "Folds" },
			{ "<leader>do", desc = "Open All Folds" },
			{ "<leader>dF", desc = "Close All Folds" },
			{ "<leader>dt", desc = "Toggle Fold" },
			{ "<leader>da", desc = "Toggle All Folds" },

			-- Refactor group
			{ "<leader>r", group = "Refactor" },
			{ "<leader>rn", desc = "Rename Symbol" },

			-- Neo-tree/Noice group
			{ "<leader>n", group = "Neo-tree/Noice" },
			{ "<leader>nt", desc = "Toggle Neo-tree" },
			{ "<leader>nl", desc = "Open Noice" },

			-- Clear group
			{ "<leader>c", group = "Clear" },
			{ "<leader>cq", desc = "Clear Quickfix" },

			-- Visual mode mappings
			{ "J", desc = "Move Line Down", mode = "v" },
			{ "K", desc = "Move Line Up", mode = "v" },
			{ "*", desc = "Go to First Non-blank", mode = "v" },
			{ "$", desc = "Go to Last Non-blank", mode = "v" },
			{ "<leader>p", desc = "Paste Without Yank", mode = "v" },
			{ "<leader>t", group = "Tags", mode = "v" },
			{ "<leader>tg", desc = "Add Go Tags", mode = "v" },
			{ "<leader>tr", desc = "Remove Go Tags", mode = "v" },

			-- Operator-pending mode mappings
			{ "*", desc = "Go to First Non-blank", mode = "o" },
			{ "$", desc = "Go to Last Non-blank", mode = "o" },
		})
	end,
}
