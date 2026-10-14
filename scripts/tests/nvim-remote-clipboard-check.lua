local module_path = "env/.config/nvim/lua/brenocrs/remote_clipboard.lua"
local original_require = _G.require

local function fail(message)
	io.stderr:write("FAIL: " .. message .. "\n")
	os.exit(1)
end

local function expect(condition, message)
	if not condition then fail(message) end
end

local function setup_case(options)
	local emitted, system_calls = {}, {}
	local parent = options.parent or 1
	local fake_osc52 = {
		copy = function(register)
			return function(lines)
				emitted[#emitted + 1] = { register = register, lines = lines }
			end
		end,
		paste = function(register)
			return function() return { "osc52-" .. register } end
		end,
	}

	_G.vim = {
		env = options.env or {},
		g = { clipboard = { name = "wl-clipboard", sentinel = true } },
		v = { shell_error = 0 },
		fn = {
			getpid = function() return 100 end,
			readfile = function(path)
				if path == "/proc/100/status" then return { "PPid:\t" .. parent } end
				if path == "/proc/50/status" then return { "PPid:\t1" } end
				if path == "/proc/50/comm" then return { options.parent_name or "shell" } end
				return {}
			end,
			executable = function(command)
				return options.executables and options.executables[command] or 0
			end,
			system = function(command, input)
				system_calls[#system_calls + 1] = { mode = "copy", command = command, input = input }
				return ""
			end,
			systemlist = function(command)
				system_calls[#system_calls + 1] = { mode = "paste", command = command }
				vim.v.shell_error = options.wl_paste_failure and 1 or 0
				return options.wl_paste_failure and {} or { "wayland-paste" }
			end,
		},
	}
	_G.require = function(name)
		if name == "vim.ui.clipboard.osc52" then
			if options.no_osc52 then error("OSC 52 unavailable") end
			return fake_osc52
		end
		return original_require(name)
	end

	local module = dofile(module_path)
	return module.setup(), vim, emitted, system_calls
end

-- Local Wayland sessions retain the existing provider untouched.
do
	local configured, v = setup_case({ env = { WAYLAND_DISPLAY = "wayland-0" }, executables = { ["wl-copy"] = 1, ["wl-paste"] = 1 } })
	expect(configured == false, "local session should not replace its clipboard provider")
	expect(v.g.clipboard.name == "wl-clipboard" and v.g.clipboard.sentinel, "local clipboard provider was changed")
end

-- SSH without local Wayland uses OSC 52 for both directions.
do
	local configured, v, emitted = setup_case({ env = { SSH_CONNECTION = "remote" } })
	expect(configured and v.g.clipboard.name == "OmarchyRemoteClipboard", "SSH should select OSC 52")
	v.g.clipboard.copy["+"]({ "remote-copy" })
	expect(emitted[1].register == "+" and emitted[1].lines[1] == "remote-copy", "SSH copy did not emit OSC 52")
	expect(v.g.clipboard.paste["+"]()[1] == "osc52-+", "SSH paste did not query OSC 52")
	expect(v.g.clipboard.cache_enabled == 0, "remote provider should disable stale clipboard cache")
end

-- tmux with a local Wayland clipboard writes both transports and pastes locally.
do
	local configured, v, emitted, calls = setup_case({
		env = { TMUX = "socket,1,0", WAYLAND_DISPLAY = "wayland-0" },
		executables = { ["wl-copy"] = 1, ["wl-paste"] = 1 },
	})
	expect(configured, "tmux should select the remote-aware provider")
	v.g.clipboard.copy["*"]({ "both-copy" })
	expect(#emitted == 1 and emitted[1].register == "*", "tmux copy should emit OSC 52")
	expect(#calls == 1 and calls[1].command[#calls[1].command] == "--primary", "primary copy should reach Wayland")
	expect(v.g.clipboard.paste["+"]()[1] == "wayland-paste", "Wayland paste should remain available")
end

-- Herdr is identified through the parent process chain when no marker is exported.
do
	local configured, v = setup_case({ parent = 50, parent_name = "herdr-agent" })
	expect(configured, "Herdr ancestry should select OSC 52")
	expect(v.g.clipboard.paste["*"]()[1] == "osc52-*", "Herdr paste should use OSC 52 without Wayland")
end

-- If Neovim lacks its OSC 52 provider, retain the configured local fallback.
do
	local configured, v = setup_case({ env = { SSH_TTY = "remote" }, no_osc52 = true })
	expect(configured == false, "missing OSC 52 must fail back without replacing clipboard config")
	expect(v.g.clipboard.name == "wl-clipboard", "missing-provider fallback changed local clipboard")
end

-- An incomplete Wayland tool pair falls back to OSC 52 instead of a broken provider.
do
	local configured, v, _, calls = setup_case({
		env = { SSH_CONNECTION = "remote", WAYLAND_DISPLAY = "wayland-0" },
		executables = { ["wl-copy"] = 1 },
	})
	expect(configured, "SSH should still enable remote clipboard without complete Wayland tools")
	expect(v.g.clipboard.paste["+"]()[1] == "osc52-+", "incomplete Wayland tools should fall back to OSC 52")
	expect(#calls == 0, "incomplete Wayland tools should not be invoked")
end

-- If a detected Wayland paste command fails, use OSC 52 for that operation.
do
	local configured, v = setup_case({
		env = { TMUX = "socket,1,0", WAYLAND_DISPLAY = "wayland-0" },
		executables = { ["wl-copy"] = 1, ["wl-paste"] = 1 },
		wl_paste_failure = true,
	})
	expect(configured, "tmux should enable remote clipboard")
	expect(v.g.clipboard.paste["+"]()[1] == "osc52-+", "failed Wayland paste should fall back to OSC 52")
end

_G.require = original_require
print("PASS: local, SSH, tmux/Wayland, Herdr ancestry, capability and command-failure fallbacks")
