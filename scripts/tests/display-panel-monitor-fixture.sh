#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/monitors.lua"
cp "$repo/env/hosts/omarchy-workstation/.config/hypr/monitors.lua" "$fixture"

# Match the variable-form persistence expressions in the installed Omarchy
# omarchy-hyprland-monitor-scaling script, operating only on the fixture.
new_scale=1.6
new_gdk_scale=2
sed -i -E \
	-e "s|^local omarchy_monitor_scale = .*|local omarchy_monitor_scale = ${new_scale}|" \
	-e "s|^local omarchy_gdk_scale = .*|local omarchy_gdk_scale = ${new_gdk_scale}|" \
	"$fixture"

grep -Fxq "local omarchy_monitor_scale = $new_scale" "$fixture"
grep -Fxq "local omarchy_gdk_scale = $new_gdk_scale" "$fixture"
grep -Fq 'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))' "$fixture"
grep -Fq 'scale = omarchy_monitor_scale' "$fixture"
grep -Fq 'local hdmi_a_1_x = math.floor(2560 / omarchy_monitor_scale)' "$fixture"
grep -Fq 'scale = 1, transform = 3' "$fixture"

[[ "$(awk -v width=2560 -v scale=1.25 'BEGIN { print int(width / scale) }')" == 2048 ]]
[[ "$(awk -v width=2560 -v scale=1.6 'BEGIN { print int(width / scale) }')" == 1600 ]]
[[ "$(awk -v px=12 'BEGIN { printf "%d", int(px * 9 / 12 + 0.5) }')" == 9 ]]
[[ "$(awk -v px=16 'BEGIN { printf "%d", int(px * 9 / 12 + 0.5) }')" == 12 ]]

printf 'display panel monitor fixture passed\n'
