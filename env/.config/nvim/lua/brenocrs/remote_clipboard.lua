-- Adapted from Omarchy's stock remote clipboard setup for this personal config.
-- Local sessions retain the wl-clipboard provider configured in set.lua.
local M = {}

local function proc_lines(pid, file)
	local ok, lines = pcall(vim.fn.readfile, "/proc/" .. pid .. "/" .. file)
	return ok and lines or {}
end

local function proc_ppid(pid)
	for _, line in ipairs(proc_lines(pid, "status")) do
		local ppid = line:match("^PPid:%s+(%d+)")
		if ppid then return tonumber(ppid) end
	end
end

local function ancestor_process_named(name)
	local pid = vim.fn.getpid()
	for _ = 1, 16 do
		local ppid = proc_ppid(pid)
		if not ppid or ppid <= 1 then return false end
		local comm = proc_lines(ppid, "comm")[1] or ""
		if comm:find(name, 1, true) then return true end
		pid = ppid
	end
	return false
end

function M.setup()
	local in_tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
	local in_ssh = (vim.env.SSH_TTY ~= nil and vim.env.SSH_TTY ~= "")
		or (vim.env.SSH_CONNECTION ~= nil and vim.env.SSH_CONNECTION ~= "")
	local in_herdr = (vim.env.HERDR_PANE_ID ~= nil and vim.env.HERDR_PANE_ID ~= "")
		or ancestor_process_named("herdr")

	if not (in_tmux or in_ssh or in_herdr) then return false end

	local ok, osc52 = pcall(require, "vim.ui.clipboard.osc52")
	if not ok or type(osc52.copy) ~= "function" or type(osc52.paste) ~= "function" then
		return false
	end

	local has_wayland = vim.env.WAYLAND_DISPLAY ~= nil
		and vim.env.WAYLAND_DISPLAY ~= ""
		and vim.fn.executable("wl-copy") == 1
		and vim.fn.executable("wl-paste") == 1

	local function copy(register)
		local emit = osc52.copy(register)
		return function(lines)
			if has_wayland then
				local cmd = { "wl-copy", "--sensitive", "--type", "text/plain" }
				if register == "*" then cmd[#cmd + 1] = "--primary" end
				vim.fn.system(cmd, lines)
			end
			if vim.g.omarchy_remote_clipboard_osc52 ~= false then emit(lines) end
		end
	end

	local function paste(register)
		if not has_wayland then return osc52.paste(register) end
		return function()
			local cmd = { "wl-paste", "--no-newline" }
			if register == "*" then cmd[#cmd + 1] = "--primary" end
			local lines = vim.fn.systemlist(cmd, "", 1)
			if vim.v.shell_error == 0 then return lines end
			return osc52.paste(register)()
		end
	end

	vim.g.clipboard = {
		name = "OmarchyRemoteClipboard",
		copy = { ["+"] = copy("+"), ["*"] = copy("*") },
		paste = { ["+"] = paste("+"), ["*"] = paste("*") },
		cache_enabled = 0,
	}
	return true
end

return M
