#!/bin/bash
# SUPER+ALT+T: toggle the Hyprland layout between dwindle (tree) and scrolling (niri style).
# general.lua is the source of truth, so the choice survives restarts.
# The CURRENT layout is read from the running Hyprland first (the file can be missing, a symlink, or say something
# else, and the toggle must still flip), then from the file when Hyprland does not answer.
GENERAL="$HOME/.config/Halcyon/hyprland/general.lua"

cur=$(hyprctl getoption general:layout -j 2>/dev/null | sed -n 's/.*"str": *"\([a-z]*\)".*/\1/p' | head -n1)
[ -n "$cur" ] || cur=$(sed -nE 's/^[[:space:]]*layout[[:space:]]*=[[:space:]]*"([a-z]+)".*/\1/p' "$GENERAL" 2>/dev/null | head -n1)

if [ "$cur" = "dwindle" ]; then
    NEW="scrolling"; NAME="Scrolling (Niri)"
else
    NEW="dwindle"; NAME="Dwindle (Tree)"
fi

live=ok
hyprctl eval "hl.config({ general = { layout = \"$NEW\" } })" >/dev/null 2>&1 || live=failed
# keep the file in step, whatever layout name it had; --follow-symlinks keeps a symlinked general.lua a symlink
if [ -w "$GENERAL" ]; then
    sed -i --follow-symlinks -E "s/^([[:space:]]*layout[[:space:]]*=[[:space:]]*)\"[a-z]+\"/\1\"$NEW\"/" "$GENERAL"
fi

if [ "$live" = ok ]; then
    notify-send "Hyprland Layout" "Switched to $NAME layout" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
else
    notify-send "Hyprland Layout" "Could not switch now (hyprctl failed); $NAME is saved for the next start" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
fi
