#!/usr/bin/env bash
# Multi-byte aware custom number formatter

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

# Use arrays instead of strings to handle multi-byte characters properly
declare -a format_hide=()
declare -a format_none=("0" "1" "2" "3" "4" "5" "6" "7" "8" "9")
declare -a format_digital=("🯰" "🯱" "🯲" "🯳" "🯴" "🯵" "🯶" "🯷" "🯸" "🯹")
declare -a format_fsquare=("󰎡" "󰎤" "󰎧" "󰎪" "󰎭" "󰎱" "󰎳" "󰎶" "󰎹" "󰎼")
declare -a format_hsquare=("󰎣" "󰎦" "󰎩" "󰎬" "󰎮" "󰎰" "󰎵" "󰎸" "󰎻" "󰎾")
declare -a format_dsquare=("󰎢" "󰎥" "󰎨" "󰎫" "󰎲" "󰎯" "󰎴" "󰎷" "󰎺" "󰎽")
declare -a format_roman=(" " "󱂈" "󱂉" "󱂊" "󱂋" "󱂌" "󱂍" "󱂎" "󱂏" "󱂐")
declare -a format_super=("⁰" "¹" "²" "³" "⁴" "⁵" "⁶" "⁷" "⁸" "⁹")
declare -a format_sub=("₀" "₁" "₂" "₃" "₄" "₅" "₆" "₇" "₈" "₉")

ID=$1
FORMAT=${2:-none}

if [ "$FORMAT" = "hide" ]; then
  exit 0
fi

# Get array name
array_name="format_${FORMAT}[@]"

# Check if format exists
if ! declare -p "format_${FORMAT}" &>/dev/null; then
  echo "$ID"  # Fallback to plain number
  exit 0
fi

# Get the array
declare -a format=("${!array_name}")

# If format is roman numerals, only handle IDs of 1 digit
if [ "$FORMAT" = "roman" ] && [ ${#ID} -gt 1 ]; then
  echo -n "$ID"
else
  result=""
  for ((i = 0; i < ${#ID}; i++)); do
    DIGIT=${ID:i:1}
    DIGIT_INDEX=$((DIGIT))
    
    # Use array indexing instead of string slicing
    char="${format[DIGIT_INDEX]}"
    result="${result}${char}"
  done
  echo -n "$result"
fi
