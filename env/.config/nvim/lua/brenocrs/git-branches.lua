-- Branch picker (telescope) for the current buffer's repo: recent first, log
-- preview, worktree-aware switching, `<type>/words-with-dashes` creation.
local repo = require("brenocrs.git-repo")

local M = {}

local TYPES = { "feat", "fix", "wip" }
local PROTECTED = { main = true, master = true, develop = true, staging = true }

local function run(root, args, on_ok)
	vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }, function(result)
		vim.schedule(function()
			if result.code == 0 then
				on_ok(result)
			else
				local msg = result.stderr ~= "" and result.stderr or result.stdout
				vim.notify(vim.trim(msg), vim.log.levels.ERROR)
			end
		end)
	end)
end

local function worktree_branches(root)
	local branches = {}
	local path = nil
	for line in vim.gsplit(repo.git(root, { "worktree", "list", "--porcelain" }) or "", "\n") do
		path = line:match("^worktree (.+)$") or path
		local branch = line:match("^branch refs/heads/(.+)$")
		if branch then
			branches[branch] = path
		end
	end
	return branches
end

local function list_branches(root)
	local format = "%(HEAD)%1f%(refname)%1f%(refname:short)%1f%(committerdate:relative)%1f%(subject)"
	local output = repo.git(root, {
		"for-each-ref",
		"--sort=-committerdate",
		"--format=" .. format,
		"refs/heads",
		"refs/remotes",
	}) or ""
	local worktrees = worktree_branches(root)
	local own_path = vim.fs.normalize(root)
	local locals = {}
	local entries = {}
	for line in vim.gsplit(output, "\n", { trimempty = true }) do
		local fields = vim.split(line, "\31", { plain = true })
		local head, ref, short, date, subject = fields[1], fields[2], fields[3], fields[4], fields[5] or ""
		local remote = vim.startswith(ref, "refs/remotes/")
		if not remote then
			locals[short] = true
		end
		if not (remote and ref:match("/HEAD$")) then
			local worktree = worktrees[short]
			if worktree and vim.fs.normalize(worktree) == own_path then
				worktree = nil
			end
			table.insert(entries, {
				name = short,
				ref = ref,
				remote = remote,
				current = head == "*",
				worktree = (not remote) and worktree or nil,
				date = date,
				subject = subject,
			})
		end
	end
	-- Hide remote branches that already have a local branch of the same name.
	return vim.tbl_filter(function(entry)
		return not (entry.remote and locals[entry.name:gsub("^[^/]+/", "")])
	end, entries)
end

local function display(entry)
	local mark = entry.current and "* " or "  "
	local where = entry.worktree and ("  [worktree " .. vim.fs.basename(entry.worktree) .. "]") or ""
	return string.format("%s%-40s %-16s%s  %s", mark, entry.name, entry.date, where, entry.subject)
end

function M.switch(root, entry)
	if entry.current then
		vim.notify("Already on " .. entry.name, vim.log.levels.INFO)
		return
	end
	if entry.worktree then
		vim.notify(entry.name .. " is checked out in worktree " .. entry.worktree, vim.log.levels.WARN)
		return
	end
	local args = entry.remote and { "switch", "--track", entry.name } or { "switch", entry.name }
	run(root, args, function()
		vim.cmd("checktime")
		vim.notify(
			"Switched to " .. (entry.remote and entry.name:gsub("^[^/]+/", "") or entry.name),
			vim.log.levels.INFO
		)
	end)
end

local function slug(text)
	local words = text:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	return words
end

local function create_from(root, name)
	local base = repo.default_base(root)
	local current = repo.git(root, { "branch", "--show-current" }) or "HEAD"
	local choices = { "Current (" .. (current ~= "" and current or "HEAD") .. ")" }
	if base then
		table.insert(choices, "Latest " .. base)
	end
	vim.ui.select(choices, { prompt = "Create " .. name .. " from" }, function(choice)
		if not choice then
			return
		end
		local done = function()
			vim.cmd("checktime")
			vim.notify("Created " .. name, vim.log.levels.INFO)
		end
		if choice == choices[1] then
			run(root, { "switch", "-c", name }, done)
			return
		end
		local remote, branch = base:match("^([^/]+)/(.+)$")
		local create = function()
			run(root, { "switch", "--no-track", "-c", name, base }, done)
		end
		if remote then
			run(root, { "fetch", remote, branch }, create)
		else
			create()
		end
	end)
end

function M.create(root, typed)
	typed = vim.trim(typed or "")
	local typed_type, typed_rest = typed:match("^(%w+)/(.+)$")
	if typed_type and vim.tbl_contains(TYPES, typed_type) then
		create_from(root, typed_type .. "/" .. slug(typed_rest))
		return
	end
	vim.ui.select(TYPES, { prompt = "Branch type" }, function(kind)
		if not kind then
			return
		end
		vim.ui.input({ prompt = kind .. "/", default = typed }, function(words)
			if not words or slug(words) == "" then
				return
			end
			create_from(root, kind .. "/" .. slug(words))
		end)
	end)
end

function M.delete(root, entry)
	if entry.remote or entry.current or entry.worktree or PROTECTED[entry.name] then
		vim.notify(
			"Not deleting " .. entry.name .. " (remote, current, protected or in a worktree)",
			vim.log.levels.WARN
		)
		return
	end
	vim.ui.select({ "No", "Yes" }, { prompt = "Delete " .. entry.name .. "?" }, function(answer)
		if answer ~= "Yes" then
			return
		end
		vim.system({ "git", "-C", root, "branch", "-d", entry.name }, { text = true }, function(result)
			vim.schedule(function()
				if result.code == 0 then
					vim.notify("Deleted " .. entry.name, vim.log.levels.INFO)
					return
				end
				vim.ui.select(
					{ "No", "Yes" },
					{ prompt = entry.name .. " is not merged. Force delete?" },
					function(force)
						if force == "Yes" then
							run(root, { "branch", "-D", entry.name }, function()
								vim.notify("Force-deleted " .. entry.name, vim.log.levels.INFO)
							end)
						end
					end
				)
			end)
		end)
	end)
end

function M.pick()
	repo.with_repo(function(root)
		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local previewers = require("telescope.previewers")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		pickers
			.new({}, {
				prompt_title = "Branches · "
					.. vim.fs.basename(root)
					.. "  (<CR> switch · <C-a> new · <C-d> delete)",
				finder = finders.new_table({
					results = list_branches(root),
					entry_maker = function(entry)
						return { value = entry, ordinal = entry.name .. " " .. entry.subject, display = display(entry) }
					end,
				}),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_termopen_previewer({
					get_command = function(entry)
						return {
							"git",
							"-C",
							root,
							"log",
							"--graph",
							"--oneline",
							"--decorate",
							"--color=always",
							"-n",
							"200",
							entry.value.ref,
						}
					end,
				}),
				attach_mappings = function(prompt_bufnr, map)
					actions.select_default:replace(function()
						local selected = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if selected then
							M.switch(root, selected.value)
						end
					end)
					map({ "i", "n" }, "<C-a>", function()
						local typed = action_state.get_current_line()
						actions.close(prompt_bufnr)
						M.create(root, typed)
					end)
					map({ "i", "n" }, "<C-d>", function()
						local selected = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if selected then
							M.delete(root, selected.value)
						end
					end)
					return true
				end,
			})
			:find()
	end)
end

function M.neogit_popup()
	repo.with_repo(function(root)
		require("neogit").open({ "branch", cwd = root })
	end)
end

return M
