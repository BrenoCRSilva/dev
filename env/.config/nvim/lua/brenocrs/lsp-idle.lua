-- Stops language servers that have had no visible buffer for a while, and starts
-- them again when one of their buffers is entered. Copilot is left alone:
-- copilot.lua starts it on InsertEnter and does not restart it by itself.
local M = {}

local defaults = {
	idle_ms = 10 * 60 * 1000,
	check_ms = 60 * 1000,
	keep = { copilot = true },
}

local last_visible = {} -- client id -> time (ms) a buffer of the client was on screen
local idle_stopped = {} -- server name -> true once the idle check stopped it

local function now()
	return vim.uv.now()
end

local function mark_visible_clients()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		for _, client in ipairs(vim.lsp.get_clients({ bufnr = vim.api.nvim_win_get_buf(win) })) do
			last_visible[client.id] = now()
		end
	end
end

local function sweep(opts)
	mark_visible_clients()
	local live = {}
	for _, client in ipairs(vim.lsp.get_clients()) do
		live[client.id] = true
		if not opts.keep[client.name] then
			last_visible[client.id] = last_visible[client.id] or now()
			if now() - last_visible[client.id] >= opts.idle_ms then
				idle_stopped[client.name] = true
				client:stop()
				live[client.id] = nil
			end
		end
	end
	for id in pairs(last_visible) do
		if not live[id] then last_visible[id] = nil end
	end
end

-- Restart a stopped server for a buffer that was just entered without one. The
-- FileType event is replayed so vim.lsp.enable() attaches the server the same
-- way it does for a newly opened buffer.
local function restart_for(buf)
	if vim.bo[buf].buftype ~= "" then return end
	local ft = vim.bo[buf].filetype
	for name in pairs(idle_stopped) do
		local config = vim.lsp.config[name]
		if config and vim.tbl_contains(config.filetypes or {}, ft)
			and #vim.lsp.get_clients({ name = name, bufnr = buf }) == 0 then
			vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
			return
		end
	end
end

function M.setup(opts)
	opts = vim.tbl_deep_extend("force", defaults, opts or {})
	local timer = vim.uv.new_timer()
	timer:start(opts.check_ms, opts.check_ms, vim.schedule_wrap(function() sweep(opts) end))
	vim.api.nvim_create_autocmd("BufEnter", {
		group = vim.api.nvim_create_augroup("brenocrs-lsp-idle", { clear = true }),
		callback = function(ev) restart_for(ev.buf) end,
	})
	return M
end

return M
