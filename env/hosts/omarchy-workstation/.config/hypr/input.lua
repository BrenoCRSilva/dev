-- US first preserves stock Latin chords; BR is the second layout.
-- Alt+Space is the historical toggle (the old Alt+I comment was stale).
-- Keep Omarchy's deliberate Caps compose / both-shifts Caps Lock behavior.
hl.config({ input = {
  kb_layout = "us,br",
  kb_variant = ",",
  kb_options = "compose:caps,shift:both_capslock_cancel,grp:alt_space_toggle",
  resolve_binds_by_sym = false,
} })
