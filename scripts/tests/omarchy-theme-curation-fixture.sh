#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source_root="$tmp/source"
themes="$tmp/home/.config/omarchy/themes"
state="$tmp/state"
mkdir -p "$source_root/8-bit/dark" "$source_root/8-bit/day" \
	"$source_root/8-bit/high-contrast" "$source_root/8-bit/day-high-contrast" \
	"$source_root/8-bit/oled" "$source_root/other/dark" "$themes"
for theme in 8-bit 8-bit-day 8-bit-high-contrast 8-bit-day-high-contrast 8-bit-oled other; do
	case "$theme" in
		8-bit) target="$source_root/8-bit/dark" ;;
		8-bit-day) target="$source_root/8-bit/day" ;;
		8-bit-high-contrast) target="$source_root/8-bit/high-contrast" ;;
		8-bit-day-high-contrast) target="$source_root/8-bit/day-high-contrast" ;;
		8-bit-oled) target="$source_root/8-bit/oled" ;;
		other) target="$source_root/other/dark" ;;
	esac
	ln -s "$target" "$themes/$theme"
done

export HOME="$tmp/home" XDG_STATE_HOME="$state"
export OMARCHY_THEMES_DIR="$themes" OMARCHY_100_THEMES_DIR="$source_root"
script="$repo/scripts/curate-100-themes.sh"

preview="$("$script")"
[[ "$preview" == *'Collection high-contrast/OLED links to remove: 3'* ]]
[[ -L "$themes/other" && -L "$themes/8-bit" && -L "$themes/8-bit-day" ]]
[[ -L "$themes/8-bit-high-contrast" && -L "$themes/8-bit-day-high-contrast" && -L "$themes/8-bit-oled" ]]

"$script" --apply > "$tmp/apply.out"
[[ -L "$themes/other" && -L "$themes/8-bit" && -L "$themes/8-bit-day" ]]
for theme in 8-bit-high-contrast 8-bit-day-high-contrast 8-bit-oled; do
	[[ ! -e "$themes/$theme" && ! -L "$themes/$theme" ]]
done
record="$(sed -n 's/^Removed .* restore record: //p' "$tmp/apply.out")"
[[ -f "$record" && "$(stat -c %a "$record")" == 600 ]]
"$script" --restore "$record" > /dev/null
[[ -L "$themes/other" && -L "$themes/8-bit" && -L "$themes/8-bit-day" ]]
[[ -L "$themes/8-bit-high-contrast" && -L "$themes/8-bit-day-high-contrast" && -L "$themes/8-bit-oled" ]]

excluded="$("$script" --list-excluded)"
[[ "$excluded" == *'8-bit-high-contrast'* ]]
[[ "$excluded" == *'8-bit-day-high-contrast'* ]]
[[ "$excluded" == *'8-bit-oled'* ]]
! grep -Fxq '8-bit-day' <<< "$excluded"
printf 'Omarchy theme curation fixture passed\n'
