#!/usr/bin/env bash
# theme.sh dark|light   tell the rest of the desktop which theme the island is using.
# The island itself (bar, panels, lock screen, Hyprland borders) follows the setting on its own; this makes GTK 3/4,
# libadwaita and portal-aware apps (Firefox, Chromium, Nautilus, ...) switch with it.
# Native helper first: `hal theme` (src/hal). Exit 2 = an older hal that does not know it yet: the bash below still works.
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  HALCYON_SCRIPTS_DIR="$(dirname "$(readlink -f "$0")")" "$hal" theme "$@" && exit 0; rc=$?
  [ "$rc" -ne 2 ] && exit "$rc"
fi
mode="${1:-dark}"
mkdir -p "$HOME/.local/state/island"
echo "$mode" > "$HOME/.local/state/island/theme"
if command -v gsettings >/dev/null 2>&1; then
  if [ "$mode" = light ]; then gsettings set org.gnome.desktop.interface color-scheme prefer-light 2>/dev/null
  else gsettings set org.gnome.desktop.interface color-scheme prefer-dark 2>/dev/null; fi
fi
bash "$(dirname "$0")/gtk-theme.sh" --auto >/dev/null 2>&1   # GTK apps (Thunar ...) get the matching colours
exit 0
