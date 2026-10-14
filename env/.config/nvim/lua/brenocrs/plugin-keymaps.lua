-- ============================================
-- PLUGIN KEYMAPS (wrapped in autocommands)
-- ============================================

-- Oil
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "oil.nvim" then
			vim.keymap.set("n", "<leader>o", "<cmd>Oil<CR>")
		end
	end,
})

-- Noice
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "noice.nvim" then
			vim.keymap.set("n", "<leader>nl", "<cmd>Noice<CR>")
		end
	end,
})

-- Undotree
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "undotree" then
			vim.keymap.set("n", "<leader>u", vim.cmd.UndotreeToggle)
		end
	end,
})

-- Grapple
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "grapple.nvim" then
			vim.keymap.set("n", "<leader>a", "<cmd>Grapple toggle<cr>")
			vim.keymap.set("n", "<leader>e", "<cmd>Grapple toggle_tags<cr>")
			vim.keymap.set("n", "<leader>1", "<cmd>Grapple select index=1<cr>")
			vim.keymap.set("n", "<leader>2", "<cmd>Grapple select index=2<cr>")
			vim.keymap.set("n", "<leader>3", "<cmd>Grapple select index=3<cr>")
			vim.keymap.set("n", "<leader>4", "<cmd>Grapple select index=4<cr>")
			vim.keymap.set("n", "<leader>5", "<cmd>Grapple select index=5<cr>")
		end
	end,
})

-- Telescope
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "telescope.nvim" then
			vim.keymap.set("n", "<leader>fa", function()
				require("telescope.builtin").find_files({ cwd = "~/", hidden = true })
			end)
			vim.keymap.set("n", "<leader>ff", function()
				require("telescope.builtin").find_files({ cwd = vim.uv.cwd() })
			end)
			vim.keymap.set("n", "<leader>fh", function()
				require("telescope.builtin").help_tags({})
			end)
			vim.keymap.set("n", "<leader>fc", function()
				require("telescope.builtin").find_files({ cwd = vim.fn.stdpath("config") })
			end)
			vim.keymap.set("n", "<leader>fb", function()
				local word = vim.fn.expand("<cword>")
				local current_file = vim.fn.expand("%:p")
				require("telescope.builtin").grep_string({ search = word, search_dirs = { current_file } })
			end)
			vim.keymap.set("n", "<leader>fw", function()
				local word = vim.fn.expand("<cword>")
				require("telescope.builtin").grep_string({ search = word })
			end)
			vim.keymap.set("n", "<leader>fW", function()
				local word = vim.fn.expand("<cWORD>")
				require("telescope.builtin").grep_string({ search = word })
			end)
			vim.keymap.set("n", "<leader>fG", function(opts)
				opts = opts or {}
				local current_file = vim.fn.expand("%:p")

				if current_file == "" then
					vim.notify("No file in current buffer", vim.log.levels.WARN)
					return
				end

				local pickers = require("telescope.pickers")
				local finders = require("telescope.finders")
				local make_entry = require("telescope.make_entry")
				local conf = require("telescope.config").values

				local finder = finders.new_async_job({
					command_generator = function(prompt)
						if not prompt or prompt == "" then
							return nil
						end

						return {
							"rg",
							"-e",
							prompt,
							current_file,
							"--color=never",
							"--no-heading",
							"--with-filename",
							"--line-number",
							"--column",
							"--smart-case",
						}
					end,
					entry_maker = make_entry.gen_from_vimgrep(opts),
					cwd = vim.fn.fnamemodify(current_file, ":h"),
				})

				pickers
					.new(opts, {
						debounce = 100,
						prompt_title = "Grep (Current Buffer)",
						finder = finder,
						previewer = conf.grep_previewer(opts),
						sorter = require("telescope.sorters").empty(),
					})
					:find()
			end)
			vim.keymap.set("n", "<leader>fg", function(opts)
				opts = opts or {}
				opts.cwd = opts.cwd or vim.uv.cwd()
				local pickers = require("telescope.pickers")
				local finders = require("telescope.finders")
				local make_entry = require("telescope.make_entry")
				local conf = require("telescope.config").values
				local finder = finders.new_async_job({
					command_generator = function(prompt)
						if not prompt or prompt == "" then
							return nil
						end
						local pieces = vim.split(prompt, "  ")
						local args = { "rg" }
						if pieces[1] then
							table.insert(args, "-e")
							table.insert(args, pieces[1])
						end
						if pieces[2] then
							table.insert(args, "-g")
							table.insert(args, pieces[2])
						end
						return vim.tbl_flatten({
							args,
							{
								"--color=never",
								"--no-heading",
								"--with-filename",
								"--line-number",
								"--column",
								"--smart-case",
							},
						})
					end,
					entry_maker = make_entry.gen_from_vimgrep(opts),
					cwd = opts.cwd,
				})
				pickers
					.new(opts, {
						debounce = 100,
						prompt_title = "Multi Grep",
						finder = finder,
						previewer = conf.grep_previewer(opts),
						sorter = require("telescope.sorters").empty(),
					})
					:find()
			end)
		end
	end,
})

-- Neogit
do
	-- Repo of the current buffer (worktree .git files match too), so git works
	-- from a task root that is not itself a repo.
	local function buf_repo_root()
		return vim.fs.root(0, ".git") or vim.uv.cwd()
	end

	local function run_git(args, opts)
		opts = opts or {}
		vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = buf_repo_root() }, function(result)
			vim.schedule(function()
				if result.code == 0 then
					if opts.success then
						vim.notify(opts.success, vim.log.levels.INFO)
					end
				else
					local msg = result.stderr ~= "" and result.stderr or result.stdout
					vim.notify(vim.trim(msg), vim.log.levels.ERROR)
				end
			end)
		end)
	end

	local function unmap_git_status()
		pcall(vim.keymap.del, "n", "<leader>gs")
	end

	vim.keymap.set("n", "<leader>gm", function()
		vim.cmd("Neogit kind=split_above cwd=" .. vim.fn.fnameescape(buf_repo_root()))
	end)
	unmap_git_status()
	vim.schedule(unmap_git_status)
	vim.defer_fn(unmap_git_status, 500)
	vim.keymap.set("n", "<leader>gp", function()
		run_git({ "push" }, { success = "Pushed" })
	end)
	vim.keymap.set("n", "<leader>go", function()
		run_git({ "push", "-u", "origin", "HEAD" }, { success = "Pushed and set upstream" })
	end)

	local PROTECTED = { main = true, master = true, develop = true, staging = true }

	local function get_main_branch()
		local ref = vim.fn.system("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null"):gsub("%s+", "")
		if ref ~= "" then
			return ref:match("refs/remotes/origin/(.+)$")
		end
		for _, name in ipairs({ "main", "master", "develop" }) do
			if vim.fn.system("git rev-parse --verify " .. name .. " 2>/dev/null") ~= "" then
				return name
			end
		end
	end

	local function get_worktree_branches()
		local active = {}
		local lines = vim.fn.systemlist("git worktree list --porcelain 2>/dev/null")
		for _, line in ipairs(lines) do
			local branch = line:match("^branch refs/heads/(.+)$")
			if branch then
				active[branch] = true
			end
		end
		return active
	end

	local function get_stashed_branches()
		local stashed = {}
		local lines = vim.fn.systemlist("git stash list 2>/dev/null")
		for _, line in ipairs(lines) do
			local branch = line:match("WIP on ([^:]+):")
			if branch then
				stashed[branch] = true
			end
		end
		return stashed
	end

	local function get_deletable_merged()
		vim.fn.system("git fetch --prune 2>/dev/null")
		local base = get_main_branch()
		if not base then
			return nil, "Could not detect main branch"
		end

		local worktree_branches = get_worktree_branches()
		local stashed_branches = get_stashed_branches()
		local merged = vim.fn.systemlist("git branch --merged " .. vim.fn.shellescape(base) .. " 2>/dev/null")
		local deletable = {}

		for _, line in ipairs(merged) do
			if line:sub(1, 1) ~= "*" then
				local name = line:gsub("^%s+", "")
				if not PROTECTED[name] and not worktree_branches[name] and not stashed_branches[name] then
					table.insert(deletable, name)
				end
			end
		end
		return deletable
	end

	vim.keymap.set("n", "<leader>gb", function()
		require("brenocrs.git-branches").pick()
	end, { desc = "Branches (picker)" })
	vim.keymap.set("n", "<leader>gB", function()
		require("brenocrs.git-branches").neogit_popup()
	end, { desc = "Branches (Neogit popup)" })

	vim.keymap.set("n", "<leader>gD", function()
		local deletable, err = get_deletable_merged()
		if not deletable then
			vim.notify(err, vim.log.levels.WARN)
			return
		end

		if #deletable == 0 then
			vim.notify("No merged branches to delete.", vim.log.levels.INFO)
			return
		end

		local items = vim.list_extend({ "!! Delete all (" .. #deletable .. ")" }, deletable)

		vim.ui.select(items, { prompt = "Delete merged branches:" }, function(choice)
			if not choice then
				return
			end
			local targets = choice:match("^!!") and deletable or { choice:gsub("^%s+", "") }
			for _, branch in ipairs(targets) do
				vim.fn.system("git branch -d " .. vim.fn.shellescape(branch))
			end
			vim.notify("Deleted: " .. table.concat(targets, ", "), vim.log.levels.INFO)
		end)
	end)

	local NeogitCfg = vim.api.nvim_create_augroup("NeogitCfg", {})
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = NeogitCfg,
		pattern = "*",
		callback = function()
			if not vim.bo.ft:match("^Neogit") then
				return
			end
			local bufnr = vim.api.nvim_get_current_buf()
			local opts = { buffer = bufnr, remap = false }

			vim.keymap.set("n", "<leader>gp", function()
				run_git({ "push" }, { success = "Pushed" })
			end, opts)
			vim.keymap.set("n", "<leader>go", function()
				run_git({ "push", "-u", "origin", "HEAD" }, { success = "Pushed and set upstream" })
			end, opts)
		end,
	})
end

-- Trouble
local current_trouble_mode = nil

vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "trouble.nvim" then
			local trouble = require("trouble")

			local function toggle_exclusive(mode)
				if trouble.is_open() and current_trouble_mode == mode then
					trouble.close()
					current_trouble_mode = nil
				else
					if trouble.is_open() then
						trouble.close()
					end
					trouble.open(mode)
					current_trouble_mode = mode
				end
			end

			vim.keymap.set("n", "<C-n>", function()
				if trouble.is_open() then
					trouble.next({ skip_groups = true, jump = true })
				end
			end)
			vim.keymap.set("n", "<C-p>", function()
				if trouble.is_open() then
					trouble.prev({ skip_groups = true, jump = true })
				end
			end)
			vim.keymap.set("n", "<leader>cq", function()
				vim.fn.setqflist({})
				trouble.refresh({ mode = "quickfix" })
			end)
			vim.keymap.set("n", "<leader>tt", function()
				toggle_exclusive("diagnostics")
			end)
			vim.keymap.set("n", "<leader>th", function()
				toggle_exclusive("buffer_diagnostics")
			end)
			vim.keymap.set("n", "<leader>tf", function()
				toggle_exclusive("quickfix")
			end)
		end
	end,
})

-- UFO (folding)
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "nvim-ufo" then
			local function is_editor_buffer()
				local buftype = vim.bo.buftype
				if buftype ~= "" then
					return false
				end

				if not vim.bo.modifiable then
					return false
				end

				local name = vim.api.nvim_buf_get_name(0)
				return not name:match("^oil://")
			end

			vim.keymap.set("n", "<leader>do", function()
				require("ufo").openAllFolds()
			end)
			vim.keymap.set("n", "<leader>dF", function()
				require("ufo").closeAllFolds()
			end)
			vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
				callback = function(args)
					if not is_editor_buffer() then
						return
					end

					vim.keymap.set("n", "<cr>", "za", { buffer = args.buf })
				end,
			})
			vim.keymap.set("n", "<leader>da", function()
				local ufo = require("ufo")
				if vim.wo.foldlevel == 0 then
					ufo.openAllFolds()
				else
					ufo.closeAllFolds()
				end
			end)
		end
	end,
})

-- Neo-tree
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "neo-tree.nvim" then
			vim.keymap.set("n", "<leader>nt", function()
				local name = vim.api.nvim_buf_get_name(0)
				if vim.bo.filetype == "oil" or name:match("^oil://") then
					vim.cmd("Neotree toggle reveal=false")
				else
					vim.cmd("Neotree toggle")
				end
			end)
		end
	end,
})

-- Go tags (filetype-specific)
vim.api.nvim_create_autocmd("FileType", {
	pattern = "go",
	callback = function()
		vim.keymap.set("v", "<leader>tg", ":AddGoTags<CR>", { silent = true, buffer = true })
		vim.keymap.set("v", "<leader>tgr", ":RemoveGoTags<CR>", { silent = true, buffer = true })
	end,
})

-- Linting (uses vim.fn.input, only in regular Neovim)
vim.keymap.set("n", "<leader>lf", function()
	local dialect = vim.fn.input("SQL Dialect: ", "clickhouse")
	if dialect ~= "" then
		vim.cmd("!sqlfluff fix --dialect=" .. dialect .. " %")
		vim.cmd("e!") -- Reload the file after fixing
	end
end, { desc = "SQLFluff fix with dialect" })

-- 99
vim.api.nvim_create_autocmd("User", {
	pattern = "LazyLoad",
	callback = function(event)
		if event.data == "99" then
			vim.keymap.set("v", "<leader>vp", function()
				require("99").visual()
			end)
		end
	end,
})
