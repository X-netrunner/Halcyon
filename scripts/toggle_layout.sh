#!/bin/bash
# SUPER+ALT+T: toggle the Hyprland layout between dwindle (tree) and scrolling (niri style).
# general.lua is the source of truth, so the choice survives restarts.
GENERAL="$HOME/.config/Halcyon/hyprland/general.lua"

if grep -Eq '^[[:space:]]*layout[[:space:]]*=[[:space:]]*"dwindle"' "$GENERAL"; then
    NEW="scrolling"; OLD="dwindle"; NAME="Scrolling (Niri)"
else
    NEW="dwindle"; OLD="scrolling"; NAME="Dwindle (Tree)"
fi

hyprctl eval "hl.config({ general = { layout = \"$NEW\" } })" >/dev/null 2>&1
sed -i -E "s/^([[:space:]]*layout[[:space:]]*=[[:space:]]*)\"$OLD\"/\1\"$NEW\"/" "$GENERAL"
notify-send "Hyprland Layout" "Switched to $NAME layout" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
