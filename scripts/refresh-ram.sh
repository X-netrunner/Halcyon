#!/usr/bin/env bash
# RAM type / speed / channels for the performance page. dmidecode needs root, the island does not, so the output is
# saved once:  ~/.cache/island/dmi-memory.txt  (and /var/lib/halcyon/dmi-memory.txt, refreshed at every boot by
# halcyon-ram.service, which install.sh sets up).
#   refresh-ram.sh          terminal: asks for sudo
#   refresh-ram.sh --gui    from the island (Settings > Detect RAM details): asks with a password window (polkit)
out="$HOME/.cache/island/dmi-memory.txt"
mkdir -p "$(dirname "$out")"
msg() { if [ "$1" = --gui ]; then notify-send -a Halcyon "RAM details" "$2" 2>/dev/null; else echo "$2"; fi; }
mode=$1
command -v dmidecode >/dev/null || { msg "$mode" "dmidecode is not installed:  sudo pacman -S dmidecode"; exit 1; }
tmp=$(mktemp)
if [ "$mode" = --gui ]; then
  pkexec dmidecode -t memory > "$tmp" 2>/dev/null
else
  sudo dmidecode -t memory > "$tmp" 2>/dev/null
fi
if grep -q "Memory Device" "$tmp"; then
  mv "$tmp" "$out"; chmod 644 "$out"
  msg "$mode" "Saved. Reopen the Performance page (or restart the island) to see type and speed."
  [ "$mode" = --gui ] || grep -E "^\s*(Size|Type|Speed|Configured Memory Speed|Locator):" "$out" | grep -v "No Module" | head -12
else
  rm -f "$tmp"
  msg "$mode" "dmidecode returned no memory info (password cancelled, or the BIOS hides it). The page keeps showing the size only."
  exit 1
fi
