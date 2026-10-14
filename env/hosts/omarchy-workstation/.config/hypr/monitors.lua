-- Verified effective displays were both scale 1; keep preferred modes flexible.
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({ output = "DP-2", mode = "preferred", position = "0x0", scale = 1 })
-- User-confirmed physical layout: HDMI-A-1 is portrait, counterclockwise,
-- immediately to the right of the 2560px-wide landscape DP-2.
-- Hyprland/Omarchy transform 3 is 270 degrees counterclockwise.
hl.monitor({ output = "HDMI-A-1", mode = "preferred", position = "2560x0", scale = 1, transform = 3 })
