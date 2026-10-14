-- Personal compatibility layer, loaded AFTER package-owned bindings.
-- See docs/KEYBINDINGS.md for displaced actions and intentionally deferred parity.
local personal_registrations = {}
local function bind(keys, description, action, options)
  -- Keep an audit of attempted personal registrations, not just the final
  -- effective map (where a later unbind could otherwise conceal duplicates).
  local parts = {}
  for part in keys:gmatch("[^+]+") do parts[#parts + 1] = part:upper():gsub("%s+", "") end
  local final = table.remove(parts)
  table.sort(parts)
  local audit_key = table.concat(parts, "+") .. "+" .. final
  assert(not personal_registrations[audit_key], "duplicate personal binding registration: " .. keys)
  personal_registrations[audit_key] = description
  hl.unbind(keys)
  o.bind(keys, description, action, options)
end
local shell = "omarchy-shell shell toggle "
-- Ctrl-Alt-Delete must not close every client without an explicit choice.
hl.unbind("CTRL + ALT + DELETE")
bind("SUPER + SPACE", "Terminal", { omarchy = "terminal" })
bind("SUPER + RETURN", "Spotlight search", shell .. "io.github.maajix.spotlight '{}'")
bind("SUPER + ESCAPE", "System menu", "omarchy-menu toggle system")
bind("SUPER + M", "Omarchy menu", "omarchy-menu toggle")
bind("SUPER + T", "Theme picker", "omarchy-menu toggle style.theme")
bind("SUPER + S", "Task sessionizer", "/home/pontual/.config/tmux/scripts/task-sessionizer.sh popup")
bind("SUPER + SHIFT + T", "Toggle window floating/tiling", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + CTRL + ALT + S", "Toggle scratchpad", hl.dsp.workspace.toggle_special("scratchpad"))
-- Spotlight is the personal search integration; the searchable root menu is Super+M.
hl.unbind("SUPER + ALT + M") -- Spotify moves to Entertainment
for _, chord in ipairs({
  "SUPER + SHIFT + M", "SUPER + SHIFT + D", "SUPER + SHIFT + G",
  "SUPER + SHIFT + N", "SUPER + SHIFT + O", "SUPER + SHIFT + W", "SUPER + SHIFT + SLASH",
  "SUPER + SHIFT + A", "SUPER + SHIFT + ALT + A", "SUPER + SHIFT + CTRL + A",
  "SUPER + SHIFT + C", "SUPER + SHIFT + E", "SUPER + SHIFT + ALT + E",
  "SUPER + SHIFT + Y", "SUPER + SHIFT + ALT + G", "SUPER + SHIFT + CTRL + G",
  "SUPER + SHIFT + P", "SUPER + SHIFT + S", "SUPER + SHIFT + X",
  "SUPER + SHIFT + ALT + X",
}) do hl.unbind(chord) end
bind("SUPER + SHIFT + D", "Development", "omarchy-menu toggle pontual-development")
bind("SUPER + SHIFT + E", "Entertainment", "omarchy-menu toggle pontual-entertainment")
bind("SUPER + SHIFT + C", "Communication", "omarchy-menu toggle pontual-communication")
bind("SUPER + SHIFT + P", "Pseudo window", hl.dsp.window.pseudo())

local directions = { H = "l", J = "d", K = "u", L = "r", LEFT = "l", DOWN = "d", UP = "u", RIGHT = "r" }
for key, direction in pairs(directions) do
  bind("SUPER + " .. key, "Focus window " .. direction, hl.dsp.focus({ direction = direction }))
  bind("SUPER + SHIFT + " .. key, "Move window " .. direction, hl.dsp.window.move({ direction = direction }))
  if key ~= "UP" and key ~= "DOWN" then
    bind("SUPER + CTRL + " .. key, "Focus monitor " .. direction, hl.dsp.focus({ monitor = direction }))
  end
  bind("SUPER + CTRL + SHIFT + " .. key, "Move window to monitor " .. direction, hl.dsp.window.move({ monitor = direction, follow = true }))
  -- Preserve stock directional SWAP separately from old directional MOVE.
  if #key > 1 then
    bind("SUPER + CTRL + ALT + " .. key, "Swap window " .. direction, hl.dsp.window.swap({ direction = direction }))
  end
end
bind("SUPER + R", "Toggle window split", hl.dsp.layout("togglesplit"))
bind("SUPER + Q", "Close window", hl.dsp.window.close())
bind("SUPER + W", "Toggle window grouping", hl.dsp.group.toggle())
-- G remains a documented stock grouping alias; the old effects script is absent.
bind("SUPER + F", "Fullscreen window", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("SUPER + SHIFT + F", "Maximize window", hl.dsp.window.fullscreen({ mode = "maximized" }))
bind("SUPER + ALT + F", "File manager", "uwsm-app -- $HOME/.local/bin/strata $HOME")
bind("SUPER + ALT + SHIFT + F", "File manager (cwd)", "uwsm-app -- $HOME/.local/bin/strata \"$(omarchy-cmd-terminal-cwd)\"")
bind("SUPER + E", "File manager", "uwsm-app -- \"$HOME/.local/bin/strata\" \"$HOME\"")
bind("SUPER + ALT + L", "Lock system", "omarchy-system-lock")
bind("SUPER + CTRL + ALT + L", "Toggle workspace layout", "omarchy-hyprland-workspace-layout-toggle")
bind("SUPER + SLASH", "Keybindings", "omarchy-menu-keybindings")
bind("SUPER + CTRL + ALT + SLASH", "Monitor scaling up", "omarchy-hyprland-monitor-scaling up")
bind("SUPER + CTRL + ALT + H", "Hardware menu", "omarchy-menu toggle hardware")
bind("SUPER + CTRL + ALT + K", "Herdr keybindings", "omarchy-menu-herdr-keybindings")
bind("SUPER + bracketleft", "Previous grouped window", hl.dsp.group.prev())
bind("SUPER + bracketright", "Next grouped window", hl.dsp.group.next())

bind("SUPER + U", "Next existing workspace", hl.dsp.focus({ workspace = "e+1" }))
for _, item in ipairs({ { "I", "e-1" }, { "U", "e+1" }, { "UP", "e-1" }, { "DOWN", "e+1" }, { "mouse_up", "e-1" }, { "mouse_down", "e+1" } }) do
  bind("SUPER + CTRL + " .. item[1], "Move and follow existing workspace " .. item[2], hl.dsp.window.move({ workspace = item[2], follow = true }))
end
for _, item in ipairs({ { "I", "e-1" }, { "U", "e+1" }, { "Prior", "e-1" }, { "Next", "e+1" } }) do
  bind("SUPER + SHIFT + " .. item[1], "Move and follow existing workspace " .. item[2], hl.dsp.window.move({ workspace = item[2], follow = true }))
end
bind("SUPER + Prior", "Previous existing workspace", hl.dsp.focus({ workspace = "e-1" }))
bind("SUPER + Next", "Next existing workspace", hl.dsp.focus({ workspace = "e+1" }))
bind("SUPER + CTRL + ALT + I", "Toggle locking on idle", "omarchy-toggle-idle")
-- No overview implementation: retain stock Tab cycle, explicitly documented.

-- App and settings chords open native Omarchy menu routes. Bind() explicitly
-- replaces the prior clipboard, hardware, quick-settings, audio and system
-- actions on these exact bare chords; displaced utilities remain in menus/bar.
bind("SUPER + N", "Notes and writing", "omarchy-menu toggle pontual-notes")
bind("SUPER + A", "AI tools", "omarchy-menu toggle pontual-ai")
bind("SUPER + comma", "Settings", "omarchy-menu toggle setup")
bind("SUPER + X", "Session and power", "omarchy-menu toggle system")
bind("SUPER + CTRL + C", "Capture and clipboard", "omarchy-menu toggle trigger.capture")
bind("SUPER + P", "Region screenshot", "omarchy-capture-screenshot region")
bind("PRINT", "Region screenshot", "omarchy-capture-screenshot region")
bind("ALT + PRINT", "Window / monitor screenshot picker", "omarchy-capture-screenshot windows")
bind("CTRL + PRINT", "Fullscreen screenshot", "omarchy-capture-screenshot fullscreen")
bind("CTRL + ALT + PRINT", "Screen recording", "omarchy-capture-screenrecording --stop-recording || omarchy-menu toggle trigger.capture.screenrecord")
bind("SUPER + Y", "Clipboard history", shell .. "omarchy.clipboard")
bind("SUPER + CTRL + ALT + comma", "Dismiss last notification", "omarchy-shell notifications dismissOne")
-- Preserve non-app utility and media chords; categorized app launch aliases are
-- explicitly unbound above and their menu rows replace them.
for _, item in ipairs({ { "XF86AudioRaiseVolume", "+3" }, { "XF86AudioLowerVolume", "-3" } }) do
  bind(item[1], "Volume " .. item[2], "omarchy-audio-output-volume " .. item[2], { locked = true, repeating = true })
end

-- Preserve Omarchy's terminal-aware universal clipboard behavior on its native chords.
-- This mirrors Omarchy's focused-surface send_key_state helper; do not replace it
-- with a virtual keyboard, which would merge the physically held Super modifier.
local function send_once(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.timer(function() hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" })) end, { timeout = 50, type = "oneshot" })
end
bind("SUPER + C", "Universal copy", function()
  local terminal = false
  local window = hl.get_active_window()
  for _, tag in ipairs(window and window.tags or {}) do
    if tag:gsub("%*$", "") == "terminal" then terminal = true end
  end
  send_once("CTRL", terminal and "Insert" or "C")
end)
bind("SUPER + V", "Universal paste", function()
  local terminal = false
  local window = hl.get_active_window()
  for _, tag in ipairs(window and window.tags or {}) do
    if tag:gsub("%*$", "") == "terminal" then terminal = true end
  end
  send_once(terminal and "SHIFT" or "CTRL", terminal and "Insert" or "V")
end)
bind("SUPER + CTRL + ALT + X", "Universal cut", function() send_once("CTRL", "X") end)
