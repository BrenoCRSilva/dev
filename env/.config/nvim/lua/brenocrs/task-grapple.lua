-- Task nvim: when nvim starts at a task root (a folder with .task-worker-order,
-- written by task-sessionizer.sh), Grapple uses a "task" scope of its own and
-- holds one tag per worker worktree, named after the repo, in worker order.
-- The tags follow .task-worker-order when a repo is added, promoted or removed.
local M = {}

local ORDER = ".task-worker-order"

-- Seeded tags are direct children of the root named after their folder; any
-- other tag in the scope is the user's and is left alone.
local function sync(root)
	local grapple = require("grapple")
	local names, want = {}, {}
	local ok, lines = pcall(vim.fn.readfile, root .. "/" .. ORDER)
	for _, name in ipairs(ok and lines or {}) do
		if name ~= "" and not want[name] and vim.fn.isdirectory(root .. "/" .. name) == 1 then
			table.insert(names, name)
			want[name] = true
		end
	end
	for _, tag in ipairs(grapple.tags({ scope = "task" }) or {}) do
		local path = tag.path:gsub("/$", "") -- Grapple stores a folder with a trailing slash
		local base = vim.fn.fnamemodify(path, ":t")
		if vim.fn.fnamemodify(path, ":h") == root and tag.name == base and not want[base] then
			grapple.untag({ path = tag.path, scope = "task" })
		end
	end
	for i, name in ipairs(names) do
		grapple.tag({ path = root .. "/" .. name, name = name, index = i, scope = "task" })
	end
end

-- Runs at startup and from the fs_event callback, so a Grapple error is a
-- warning, never a throw.
function M.sync(root)
	local ok, err = pcall(sync, root)
	if not ok then
		vim.notify("task-grapple: " .. tostring(err), vim.log.levels.WARN)
	end
end

function M.setup()
	local root = vim.uv.cwd()
	if not root or vim.fn.filereadable(root .. "/" .. ORDER) == 0 then
		return
	end
	local ok, grapple = pcall(require, "grapple")
	if not ok then
		return
	end
	-- The id is prefixed so the task tags never share a container with the
	-- cwd/git scope of the same folder.
	grapple.define_scope({
		name = "task",
		desc = "Task worktrees",
		force = true,
		resolver = function()
			return "task:" .. root, root
		end,
	})
	grapple.use_scope("task", { notify = false })
	M.sync(root)

	-- .task-worker-order is replaced by a rename, so the folder is watched.
	local watcher = vim.uv.new_fs_event()
	if watcher then
		watcher:start(root, {}, function(_, filename)
			if filename == nil or filename == ORDER then
				vim.schedule(function()
					M.sync(root)
				end)
			end
		end)
	end
end

return M
