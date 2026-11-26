#!/usr/bin/env bash
# d2t - run D2 with the house font (Arial) and the Tala layout engine, so SVGs match the phd / work slide themes.
#
#   ./d2t.sh figures/pipeline.d2 figures/pipeline.svg
#   ./d2t.sh --watch figures/pipeline.d2 figures/pipeline.svg
#
# Any normal d2 flag works. D2 embeds the font into the SVG, so the figure looks the same on any machine.
# Font lookup: Windows (Git Bash/MSYS) → macOS → Linux (Liberation Sans, metric-compatible with Arial).
set -euo pipefail

find_font() {   # find_font <file> [<file> ...] -> first existing path in the usual font folders
  local dirs=("C:/Windows/Fonts" "/c/Windows/Fonts" "/Library/Fonts" "/System/Library/Fonts/Supplemental"
              "/usr/share/fonts/truetype/msttcorefonts" "/usr/share/fonts/truetype/liberation" "/usr/share/fonts/liberation")
  local d f
  for f in "$@"; do for d in "${dirs[@]}"; do [ -f "$d/$f" ] && { echo "$d/$f"; return 0; }; done; done
  return 1
}

REG=$(find_font arial.ttf Arial.ttf LiberationSans-Regular.ttf || true)
ITA=$(find_font ariali.ttf "Arial Italic.ttf" LiberationSans-Italic.ttf || true)
BLD=$(find_font arialbd.ttf "Arial Bold.ttf" LiberationSans-Bold.ttf || true)

# Default to the Tala layout engine unless --layout / -l or D2_LAYOUT is given (matches d2t.ps1).
LAYOUT=()
has_layout=false
for a in "$@"; do
  case "$a" in --layout|--layout=*|-l|-l=*) has_layout=true ;; esac
done
if ! $has_layout && [ -z "${D2_LAYOUT:-}" ]; then LAYOUT=(--layout tala); fi

if [ -z "$REG" ] || [ -z "$ITA" ] || [ -z "$BLD" ]; then
  echo "d2t: Arial (or Liberation Sans) not found; using D2's default font." >&2
  exec d2 ${LAYOUT[@]+"${LAYOUT[@]}"} "$@"   # (expansion form is safe for empty arrays on bash 3.2 + set -u)
fi

# Arial has no semibold: D2's semibold slots use Arial Bold.
exec d2 --font-regular "$REG" --font-italic "$ITA" --font-bold "$BLD" --font-semibold "$BLD" ${LAYOUT[@]+"${LAYOUT[@]}"} "$@"
