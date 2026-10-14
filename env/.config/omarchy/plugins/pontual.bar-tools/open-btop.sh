#!/usr/bin/env bash
set -euo pipefail

command -v btop >/dev/null || {
  notify-send 'System monitor unavailable' 'Install btop before using this action'
  exit 0
}

clients=$(hyprctl -j clients)
address=$(jq -r '.[] | select(.class == "org.omarchy.btop") | .address' <<<"$clients" | head -n 1)
if [[ -z "$address" ]]; then
  omarchy-launch-or-focus-tui btop
  for _ in {1..40}; do
    clients=$(hyprctl -j clients)
    address=$(jq -r '.[] | select(.class == "org.omarchy.btop") | .address' <<<"$clients" | head -n 1)
    [[ -n "$address" ]] && break
    sleep 0.05
  done
fi
[[ -n "$address" ]] || {
  notify-send 'System monitor unavailable' 'Could not find the btop window after launch'
  exit 1
}

hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })" >/dev/null
for _ in {1..30}; do
  active=$(hyprctl -j activewindow | jq -r '.address // empty')
  [[ "$active" == "$address" ]] && break
  sleep 0.05
done
[[ "${active:-}" == "$address" ]] || {
  notify-send 'System monitor unavailable' 'Could not focus the existing btop window'
  exit 1
}

read -r width height monitor_id < <(jq -r --arg address "$address" '.[] | select(.address == $address) | "\(.size[0]) \(.size[1]) \(.monitor)"' <<<"$clients")
monitor_width=$(hyprctl -j monitors | jq -r --argjson monitor "$monitor_id" '.[] | select(.id == $monitor) | .width' | head -n 1)
target_width=1200
if [[ "$monitor_width" =~ ^[0-9]+$ ]] && (( monitor_width > 0 && target_width > monitor_width - 24 )); then
  target_width=$((monitor_width - 24))
fi
delta_width=$((target_width - width))
delta_height=$((800 - height))
if (( delta_width != 0 || delta_height != 0 )); then
  hyprctl dispatch "hl.dsp.window.resize({ x = $delta_width, y = $delta_height, relative = true })" >/dev/null
fi
