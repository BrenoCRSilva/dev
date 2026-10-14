-- Numeric identity stays 1..10; icons are presentation in pontual.workspaces.
-- Enable a monitor assignment only while that output exists.
-- Do not move existing windows/workspaces on reload; rules govern allocation.
local routes = {}
for workspace = 1, 10 do
  local output = workspace <= 5 and "DP-2" or "HDMI-A-1"
  routes[workspace] = {
    output = output,
    preferred = hl.workspace_rule({ workspace = tostring(workspace), monitor = output }),
  }
end
local function refresh()
  for _, route in ipairs(routes) do
    local available = hl.get_monitor(route.output) ~= nil
    route.preferred:set_enabled(available)
  end
end
refresh()
hl.on("monitor.added", refresh)
hl.on("monitor.removed", refresh)
hl.on("hyprland.start", refresh)
-- Exact IDs observed in current installed app definitions / desktop IDs.
-- Route only main Steam UI: no generic games or PiP rule is replaced.
o.window("^(com\\.mitchellh\\.ghostty|ghostty)$", { workspace = "1" })
o.window("^brave-browser$", { workspace = "2" })
-- These two Brave PWA classes were read from current client metadata. Their
-- target workspaces follow the existing 1-5 DP-2 / 6-10 HDMI-A-1 map.
-- Rules affect future allocations only; existing windows are never moved.
o.window("^brave-youtube\\.com__-Default$", { workspace = "5" })
o.window("^brave-web\\.whatsapp\\.com__-Default$", { workspace = "7" })
o.window({ class = "^steam$", title = "^Steam$" }, { workspace = "4" })
o.window("^(Spotify|spotify)$", { workspace = "10" })

-- Historical-only classes are intentionally opt-in until observed on real windows.
-- Add verified personal rules here; see docs/KEYBINDINGS.md for the exact IDs.
local historical_routes_enabled = false -- opt in ONLY after hyprctl clients class verification
local historical_routes = {
  { "^install4j-t3-dataman-mongodb-app-Studio3TApp$", 1 },
  { "^brave-fmpnliohjhemenmnlpbfagaolkdacoja-Default$", 3 },
  { "^brave-agimnkijcaahngcdmfeangaknmldooml-Default$", 5 },
  { "^brave-hnpfjngllnobngcgfapefoaidbinmjnm-Default$", 7 },
  { "^brave-ompifgpmddkgmclendfeacglnodjjndh-Default$", 8 },
  { "^vesktop$", 9 },
}
if historical_routes_enabled then
  for _, route in ipairs(historical_routes) do
    o.window(route[1], { workspace = tostring(route[2]) .. " silent" })
  end
end
