-- Preserve the active Omarchy-generated palette; customize geometry only.
hl.config({
  general = { gaps_in = 5, gaps_out = 10, border_size = 2 },
  decoration = { rounding = 12, shadow = { enabled = true } },
})

-- Stock Omarchy disables blur. Spotlight's translucent card and Ghostty's
-- background-blur-radius both rely on it, so enable it and frost Spotlight.
hl.config({ decoration = { blur = { enabled = true } } })
hl.layer_rule({ match = { namespace = "^omarchy-spotlight$" }, blur = true, ignore_alpha = 0.2 })
