#!/usr/bin/env bash
# theme.sh dark|light   tell the rest of the desktop which theme the island is using.
# The island itself (bar, panels, lock screen, Hyprland borders) follows the setting on its own; this makes GTK 3/4,
# libadwaita and portal-aware apps (Firefox, Chromium, Nautilus, ...) switch with it.
mode="${1:-dark}"
mkdir -p "$HOME/.local/state/island"
echo "$mode" > "$HOME/.local/state/island/theme"
if command -v gsettings >/dev/null 2>&1; then
  if [ "$mode" = light ]; then gsettings set org.gnome.desktop.interface color-scheme prefer-light 2>/dev/null
  else gsettings set org.gnome.desktop.interface color-scheme prefer-dark 2>/dev/null; fi
fi
exit 0
