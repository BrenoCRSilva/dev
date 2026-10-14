-- Keep these exact Omarchy variable names: the monitor-scaling panel edits
-- them in place so its selection survives Hyprland's config autoreload.
local omarchy_monitor_scale = 1.25
local omarchy_gdk_scale = 1

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
hl.monitor({ output = "DP-2", mode = "preferred", position = "0x0", scale = omarchy_monitor_scale })

-- HDMI-A-1 is portrait (transform 3), scale 1, directly right of DP-2.
-- Hyprland positions monitors in logical pixels after scaling DP-2's width.
local hdmi_a_1_x = math.floor(2560 / omarchy_monitor_scale)
hl.monitor({ output = "HDMI-A-1", mode = "preferred", position = tostring(hdmi_a_1_x) .. "x0", scale = 1, transform = 3 })
