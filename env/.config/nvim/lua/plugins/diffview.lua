-- PR-style review: diff on top, file list / history panel at the bottom, the
-- working-tree side editable. In a task root (no .git), pick one of its worktrees.
local repo = require("brenocrs.git-repo")

local function diffview(command, root, rest)
	local parts = { command, vim.fn.fnameescape("-C" .. root) }
	if rest then
		table.insert(parts, rest)
	end
	vim.cmd(table.concat(parts, " "))
end

local function review_changes()
	repo.with_repo(function(root)
		diffview("DiffviewOpen", root)
	end)
end

-- Merge-base against the working tree: every change of the branch, committed
-- or not, with the right side editable.
local function review_branch()
	repo.with_repo(function(root)
		local base = repo.default_base(root)
		if not base then
			vim.notify("No main/master branch found in " .. root, vim.log.levels.WARN)
			return
		end
		local merge_base = repo.git(root, { "merge-base", base, "HEAD" })
		if not merge_base then
			vim.notify("No merge-base between " .. base .. " and HEAD", vim.log.levels.WARN)
			return
		end
		vim.notify("Reviewing " .. vim.fs.basename(root) .. " against " .. base, vim.log.levels.INFO)
		diffview("DiffviewOpen", root, merge_base)
	end)
end

local function repo_history()
	repo.with_repo(function(root)
		diffview("DiffviewFileHistory", root)
	end)
end

local close = { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } }

return {
	"sindrets/diffview.nvim",
	cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewToggleFiles", "DiffviewRefresh" },
	keys = {
		{ "<leader>gd", review_changes, desc = "Review uncommitted changes" },
		{ "<leader>gr", review_branch, desc = "Review branch (vs main/master)" },
		{ "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "File history" },
		{ "<leader>gH", repo_history, desc = "Repository history" },
		{ "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Close diffview" },
	},
	opts = {
		enhanced_diff_hl = true,
		view = {
			default = { layout = "diff2_horizontal" },
			file_history = { layout = "diff2_horizontal" },
			merge_tool = { layout = "diff3_mixed" },
		},
		file_panel = {
			listing_style = "list",
			win_config = { position = "bottom", height = 14 },
		},
		file_history_panel = {
			win_config = { position = "bottom", height = 16 },
		},
		hooks = {
			-- Look of the diffview README: relative numbers, cursorline, ╱ where lines are missing.
			diff_buf_win_enter = function(_, winid)
				vim.wo[winid].number = true
				vim.wo[winid].relativenumber = true
				vim.wo[winid].cursorline = true
				vim.wo[winid].cursorlineopt = "both"
				vim.wo[winid].fillchars = vim.o.fillchars .. ",diff:╱"
			end,
		},
		keymaps = {
			view = { close },
			file_panel = { close },
			file_history_panel = { close },
		},
	},
}
