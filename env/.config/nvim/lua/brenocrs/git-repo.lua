-- Git helpers shared by the review (diffview) and branch pickers: resolve the
-- repo of the current buffer, or pick a worktree when started in a task root.
local M = {}

function M.git(root, args)
	local result = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
	if result.code ~= 0 then
		return nil
	end
	return vim.trim(result.stdout)
end

function M.with_repo(callback)
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

function M.default_base(root)
	local remote_head = M.git(root, { "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })
	if remote_head and remote_head ~= "" then
		return remote_head
	end
	for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
		if M.git(root, { "rev-parse", "--verify", "--quiet", candidate }) then
			return candidate
		end
	end
	return nil
end

return M
