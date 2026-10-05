#!/usr/bin/env bash
# Reload Hyprland AND the rice config:
#   1. hyprctl reload              (re-reads ~/.config/Halcyon/hyprland.lua and every file it loads)
#   2. terminal colours            (re-written from the current palette and re-applied to open terminals)
# The island itself (quickshell) is reloaded by the island right after this script exits.
hyprctl reload >/dev/null 2>&1
bash "$(dirname "$0")/term-colors.sh" >/dev/null 2>&1
exit 0
