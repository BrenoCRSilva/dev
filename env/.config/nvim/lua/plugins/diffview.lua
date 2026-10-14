-- PR-style review: a file panel on the left, one diff per file, the working-tree
-- side editable. In a task root (no .git), pick one of its worktrees.
local function git(root, args)
	local result = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
	if result.code ~= 0 then
		return nil
	end
	return vim.trim(result.stdout)
end

local function with_repo(callback)
	local start = vim.uv.cwd()
	local name = vim.api.nvim_buf_get_name(0)
	if vim.bo.buftype == "" and name ~= "" then
		start = vim.fs.dirname(name)
	end
	local root = vim.fs.root(start, ".git")
	if root then
		callback(root)
		return
	end

	local task_root = vim.g.task_root
	if not task_root then
		vim.notify("Not inside a git repository", vim.log.levels.WARN)
		return
	end
	local repos = {}
	for entry in vim.fs.dir(task_root) do
		if vim.uv.fs_stat(task_root .. "/" .. entry .. "/.git") then
			table.insert(repos, task_root .. "/" .. entry)
		end
	end
	if #repos == 0 then
		vim.notify("No repositories in " .. task_root, vim.log.levels.WARN)
	elseif #repos == 1 then
		callback(repos[1])
	else
		table.sort(repos)
		vim.ui.select(repos, {
			prompt = "Repository",
			format_item = function(path)
				return vim.fs.basename(path)
			end,
		}, function(choice)
			if choice then
				callback(choice)
			end
		end)
	end
end

local function default_base(root)
	local remote_head = git(root, { "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })
	if remote_head and remote_head ~= "" then
		return remote_head
	end
	for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
		if git(root, { "rev-parse", "--verify", "--quiet", candidate }) then
			return candidate
		end
	end
	return nil
end

local function diffview(command, root, rest)
	local parts = { command, vim.fn.fnameescape("-C" .. root) }
	if rest then
		table.insert(parts, rest)
	end
	vim.cmd(table.concat(parts, " "))
end

local function review_changes()
	with_repo(function(root)
		diffview("DiffviewOpen", root)
	end)
end

-- Merge-base against the working tree: every change of the branch, committed
-- or not, with the right side editable.
local function review_branch()
	with_repo(function(root)
		local base = default_base(root)
		if not base then
			vim.notify("No main/master branch found in " .. root, vim.log.levels.WARN)
			return
		end
		local merge_base = git(root, { "merge-base", base, "HEAD" })
		if not merge_base then
			vim.notify("No merge-base between " .. base .. " and HEAD", vim.log.levels.WARN)
			return
		end
		vim.notify("Reviewing " .. vim.fs.basename(root) .. " against " .. base, vim.log.levels.INFO)
		diffview("DiffviewOpen", root, merge_base)
	end)
end

local function repo_history()
	with_repo(function(root)
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
			merge_tool = { layout = "diff3_mixed" },
		},
		file_panel = {
			listing_style = "tree",
			win_config = { position = "left", width = 35 },
		},
		keymaps = {
			view = { close },
			file_panel = { close },
			file_history_panel = { close },
		},
	},
}
