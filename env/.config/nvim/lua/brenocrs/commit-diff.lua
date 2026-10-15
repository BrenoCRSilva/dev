-- Commit diffs in diffview: pick a commit from the current branch (<leader>gc),
-- or two (<leader>gC), or take a rev (:DiffCommit). The repo is resolved with
-- repo.with_repo, the same as gd and gr.
local repo = require("brenocrs.git-repo")

local M = {}

-- Range for one commit: sha^! (against its parent) for a normal commit,
-- <empty tree>..sha for a root commit, and sha^1..sha (first parent) for a merge.
function M.commit_range(root, sha)
	local line = repo.git(root, { "rev-list", "--parents", "-n", "1", sha })
	if not line then
		return nil, "Not a commit: " .. sha
	end
	local parents = vim.list_slice(vim.split(line, " ", { plain = true }), 2)
	if #parents == 0 then
		local empty = repo.git(root, { "hash-object", "-t", "tree", "/dev/null" })
		return empty .. ".." .. sha
	end
	if #parents > 1 then
		return sha .. "^1.." .. sha
	end
	return sha .. "^!"
end

local function is_ancestor(root, a, b)
	return vim.system({ "git", "-C", root, "merge-base", "--is-ancestor", a, b }, { text = true }):wait().code == 0
end

-- "older..newer" for two commits: by ancestry when related, else by commit time.
function M.between(root, a, b)
	local older, newer = a, b
	if is_ancestor(root, b, a) then
		older, newer = b, a
	elseif not is_ancestor(root, a, b) then
		local ta = tonumber(repo.git(root, { "show", "-s", "--format=%ct", a }) or "0")
		local tb = tonumber(repo.git(root, { "show", "-s", "--format=%ct", b }) or "0")
		if tb < ta then
			older, newer = b, a
		end
	end
	return older .. ".." .. newer
end

function M.open(root, range)
	vim.cmd("DiffviewOpen " .. vim.fn.fnameescape("-C" .. root) .. " " .. range)
end

-- Commits on the current branch, newest first.
function M.log(root)
	local out = repo.git(root, { "log", "-n", "300", "--format=%H%x1f%h%x1f%s%x1f%an%x1f%cr" }) or ""
	local entries = {}
	for line in vim.gsplit(out, "\n", { trimempty = true }) do
		local f = vim.split(line, "\31", { plain = true })
		entries[#entries + 1] = { sha = f[1], short = f[2], subject = f[3] or "", author = f[4] or "", date = f[5] or "" }
	end
	return entries
end

local function pick(root, title, on_select)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local previewers = require("telescope.previewers")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = title .. " · " .. vim.fs.basename(root),
			finder = finders.new_table({
				results = M.log(root),
				entry_maker = function(entry)
					return {
						value = entry,
						ordinal = entry.short .. " " .. entry.subject .. " " .. entry.author,
						display = string.format("%s  %s  (%s, %s)", entry.short, entry.subject, entry.author, entry.date),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_termopen_previewer({
				get_command = function(entry)
					return { "git", "-C", root, "show", "--stat", "--format=%h %s%n%an, %cr", entry.value.sha }
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selected = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selected then
						on_select(selected.value)
					end
				end)
				return true
			end,
		})
		:find()
end

-- <leader>gc
function M.pick_commit()
	repo.with_repo(function(root)
		pick(root, "Commit diff", function(entry)
			local range, err = M.commit_range(root, entry.sha)
			if not range then
				return vim.notify(err, vim.log.levels.WARN)
			end
			M.open(root, range)
		end)
	end)
end

-- <leader>gC
function M.pick_range()
	repo.with_repo(function(root)
		pick(root, "Diff from commit", function(first)
			pick(root, "Diff to commit", function(second)
				if first.sha == second.sha then
					return vim.notify("Pick two different commits", vim.log.levels.WARN)
				end
				M.open(root, M.between(root, first.sha, second.sha))
			end)
		end)
	end)
end

-- :DiffCommit <rev>
function M.diff_rev(rev)
	repo.with_repo(function(root)
		local sha = repo.git(root, { "rev-parse", "--verify", "--quiet", rev .. "^{commit}" })
		if not sha then
			return vim.notify("Not a commit: " .. rev, vim.log.levels.WARN)
		end
		local range, err = M.commit_range(root, sha)
		if not range then
			return vim.notify(err, vim.log.levels.WARN)
		end
		M.open(root, range)
	end)
end

-- Completion: the newest commit hashes of the repo at the cursor, or the cwd.
function M.complete_revs(arglead)
	local start = vim.api.nvim_buf_get_name(0)
	local root = vim.fs.root(start ~= "" and vim.fs.dirname(start) or vim.uv.cwd(), ".git")
	if not root then
		return {}
	end
	local out = repo.git(root, { "log", "-n", "50", "--format=%h" }) or ""
	return vim.tbl_filter(function(sha)
		return vim.startswith(sha, arglead)
	end, vim.split(out, "\n", { trimempty = true }))
end

return M
