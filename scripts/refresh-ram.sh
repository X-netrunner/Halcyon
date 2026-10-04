#!/usr/bin/env bash
# Saves the RAM details (type, speed, channels) that the Performance page shows. dmidecode needs root, the island does not,
# so it is read once here and cached in ~/.cache/island/dmi-memory.txt. Run again after changing RAM.
set -e
command -v dmidecode >/dev/null || { echo "dmidecode is not installed:  sudo pacman -S dmidecode"; exit 1; }
out="$HOME/.cache/island/dmi-memory.txt"
mkdir -p "$(dirname "$out")"
tmp=$(mktemp)
if sudo dmidecode -t memory > "$tmp" 2>/dev/null && grep -q "Memory Device" "$tmp"; then
  mv "$tmp" "$out"
  echo "saved $out"
  grep -E "^\s*(Size|Type|Speed|Configured Memory Speed|Form Factor|Locator):" "$out" | grep -v "No Module" | head -12
  echo "reopen the Performance page (or restart the island) to see it"
else
  rm -f "$tmp"
  echo "dmidecode gave no memory info (needs root / BIOS may hide it). The page keeps showing the size only."
  exit 1
fi
