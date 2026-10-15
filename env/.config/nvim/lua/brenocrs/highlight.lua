-- Treesitter highlighting for buffers with a real filetype. A parser missing from
-- site/parser is installed the first time a buffer of that language opens. Without
-- a highlights query, the buffer uses Vim's regex syntax instead.
local M = {}

-- Installed at startup, so these are ready before the first buffer opens.
M.core = { "c", "go", "lua", "vim", "vimdoc", "query", "markdown", "markdown_inline", "javascript", "typescript", "tsx", "json" }

local pending = {} -- lang -> buffers waiting for its install
local warned = false

local function ts()
	return require("nvim-treesitter")
end

-- The install compiles a parser with the tree-sitter CLI and a C compiler.
local function toolchain()
	local cc = vim.fn.executable("cc") == 1 or vim.fn.executable("gcc") == 1 or vim.fn.executable("clang") == 1
	return vim.fn.executable("tree-sitter") == 1 and cc
end

-- Start treesitter for a buffer, or fall back to regex syntax when the language has
-- no highlights query. A failed start is reported, not swallowed.
local function start(buf, lang)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
	if not (ok and query) then
		vim.bo[buf].syntax = vim.bo[buf].filetype
		return
	end
	local started, err = pcall(vim.treesitter.start, buf, lang)
	if not started then
		vim.notify("treesitter could not start for " .. lang .. ": " .. tostring(err), vim.log.levels.WARN)
	end
end

-- A buffer opened before its parser was installed stays broken for the rest of the
-- session, while a buffer opened afterwards works. Re-reading it from disk resets it.
-- Diffview buffers (nowrite) and modified buffers are left as they are.
local function reload(buf)
	if vim.bo[buf].buftype == "" and not vim.bo[buf].modified then
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("silent! edit")
		end)
	end
end

-- Install a parser, then start the buffers that waited for it. A buffer is
-- started only if it is still valid and still has the filetype it had when it asked.
local function install_then_start(buf, lang)
	local entry = { buf = buf, ft = vim.bo[buf].filetype }
	if pending[lang] then
		table.insert(pending[lang], entry)
		return
	end
	pending[lang] = { entry }
	ts().install({ lang }):await(function(err, result)
		vim.schedule(function()
			local waiting = pending[lang] or {}
			pending[lang] = nil
			-- query.get memoises misses, and a query installed this session stays invisible
			-- until the memo is cleared.
			vim.treesitter.query.get:clear()
			if err or result == false then
				vim.notify("Parser install failed for " .. lang .. "; using regex syntax", vim.log.levels.WARN)
			end
			for _, e in ipairs(waiting) do
				if vim.api.nvim_buf_is_valid(e.buf) and vim.bo[e.buf].filetype == e.ft then
					reload(e.buf)
					if not vim.treesitter.highlighter.active[e.buf] then
						start(e.buf, lang)
					end
				end
			end
		end)
	end)
end

-- Highlight one buffer, installing its parser first when it is missing.
function M.attach(buf)
	if not vim.api.nvim_buf_is_valid(buf) or vim.treesitter.highlighter.active[buf] then
		return
	end
	local ft = vim.bo[buf].filetype
	if ft == "" then
		return
	end
	local lang = vim.treesitter.language.get_lang(ft)
	if not lang or not vim.tbl_contains(ts().get_available(), lang) then
		return
	end
	if vim.tbl_contains(ts().get_installed(), lang) then
		return start(buf, lang)
	end
	if not toolchain() then
		if not warned then
			warned = true
			vim.notify("tree-sitter CLI or a C compiler is missing: parsers are not installed on open", vim.log.levels.WARN)
		end
		return start(buf, lang)
	end
	install_then_start(buf, lang)
end

function M.setup()
	if toolchain() then
		ts().install(M.core)
	end
	vim.api.nvim_create_autocmd("FileType", {
		group = vim.api.nvim_create_augroup("brenocrs-treesitter", { clear = true }),
		callback = function(args)
			M.attach(args.buf)
		end,
	})
end

return M
