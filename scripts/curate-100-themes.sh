#!/usr/bin/env bash
set -euo pipefail
umask 077

# Remove only the high-contrast and OLED variants from the external collection.
# All dark and day themes, and unrelated themes, remain discoverable. Default
# mode is a preview; source assets are never modified.

themes_dir="${OMARCHY_THEMES_DIR:-$HOME/.config/omarchy/themes}"
source_root="${OMARCHY_100_THEMES_DIR:-$HOME/.local/share/100-themes}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/100-themes-curation"
mode=preview
restore_file=""

usage() {
	cat <<'EOF'
Usage:
  curate-100-themes.sh                 Preview high-contrast/OLED removals (default)
  curate-100-themes.sh --apply         Remove only high-contrast/OLED collection links
  curate-100-themes.sh --list-excluded List high-contrast/OLED links by name
  curate-100-themes.sh --restore [TSV] Restore links from a prior apply record

Only collection symlinks ending in -high-contrast, -day-high-contrast, or
-oled are removed. All dark/day collection links and other user/stock themes
are untouched. The source checkout is never modified.
EOF
}

while (($#)); do
	case "$1" in
		--apply) mode=apply ;;
		--list-excluded) mode=list-excluded ;;
		--restore)
			mode=restore
			if [[ -n "${2:-}" && "$2" != -* ]]; then restore_file="$2"; shift; fi
			;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

source_root="$(realpath -e -- "$source_root" 2>/dev/null)" || {
	printf '100-themes source not found: %s\n' "$source_root" >&2
	exit 1
}

target_is_collection_link() {
	local path="$1" resolved
	[[ -L "$path" ]] || return 1
	resolved="$(realpath -e -- "$path" 2>/dev/null)" || return 1
	[[ "$resolved" == "$source_root"/* ]]
}

is_excluded_name() {
	case "$1" in
		*-high-contrast|*-day-high-contrast|*-oled) return 0 ;;
		*) return 1 ;;
	esac
}

if [[ "$mode" == restore ]]; then
	if [[ -z "$restore_file" ]]; then
		restore_file="$(find "$state_root" -maxdepth 1 -type f -name 'curation-*.tsv' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
	fi
	[[ -n "$restore_file" && -f "$restore_file" ]] || { printf 'No curation record found to restore\n' >&2; exit 1; }
	while IFS=$'\t' read -r name target; do
		[[ -n "$name" && -n "$target" ]] || continue
		resolved="$(realpath -e -- "$target" 2>/dev/null)" || { printf 'Skipping missing source for %s\n' "$name" >&2; continue; }
		[[ "$resolved" == "$source_root"/* ]] || { printf 'Skipping target outside collection for %s\n' "$name" >&2; continue; }
		if [[ -e "$themes_dir/$name" || -L "$themes_dir/$name" ]]; then
			printf 'Preserved existing path: %s\n' "$themes_dir/$name"
			continue
		fi
		printf 'Restore link: %s -> %s\n' "$themes_dir/$name" "$target"
		ln -s -- "$target" "$themes_dir/$name"
	done < "$restore_file"
	exit 0
fi

[[ -d "$themes_dir" ]] || { printf 'Theme directory not found: %s\n' "$themes_dir" >&2; exit 1; }
declare -a remove_names=() remove_targets=()
while IFS= read -r -d '' path; do
	name="${path##*/}"
	target="$(readlink -- "$path")"
	target_is_collection_link "$path" || continue
	if [[ "$mode" == list-excluded ]]; then
		is_excluded_name "$name" && printf '%s\n' "$name"
		continue
	fi
	if is_excluded_name "$name"; then
		remove_names+=("$name")
		remove_targets+=("$target")
	fi
done < <(find "$themes_dir" -mindepth 1 -maxdepth 1 -type l -print0 | sort -z)

if [[ "$mode" == list-excluded ]]; then exit 0; fi

printf 'Collection high-contrast/OLED links to remove: %d\n' "${#remove_names[@]}"
for name in "${remove_names[@]}"; do printf '  %s\n' "$name"; done

if [[ "$mode" == apply ]]; then
	mkdir -p -- "$state_root"
	chmod 700 -- "$state_root"
	record="$state_root/curation-$(date -u +%Y%m%dT%H%M%SZ).tsv"
	: > "$record"
	for i in "${!remove_names[@]}"; do
		printf '%s\t%s\n' "${remove_names[$i]}" "${remove_targets[$i]}" >> "$record"
	done
	chmod 600 -- "$record"
	for name in "${remove_names[@]}"; do
		rm -- "$themes_dir/$name"
	done
	printf 'Removed %d collection links; restore record: %s\n' "${#remove_names[@]}" "$record"
else
	printf 'Preview only; rerun with --apply to make this change.\n'
fi
