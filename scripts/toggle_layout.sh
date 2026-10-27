#!/bin/bash
# SUPER+ALT+T: toggle the Hyprland layout between dwindle, scrolling (niri style), and off (floating).
# general.lua is the source of truth for tiling, and floating-mode.sh manages off/floating mode.
GENERAL="$HOME/.config/Halcyon/hyprland/general.lua"
FLOAT_SCRIPT="$HOME/.config/Halcyon/scripts/floating-mode.sh"

is_float() {
    [ -x "$FLOAT_SCRIPT" ] && [ "$("$FLOAT_SCRIPT" status 2>/dev/null)" = "on" ]
}

target="$1"

if [ -z "$target" ] || [ "$target" = "toggle" ]; then
    if is_float; then
        target="dwindle"
    else
        cur=$(hyprctl getoption general:layout -j 2>/dev/null | sed -n 's/.*"str": *"\([a-z]*\)".*/\1/p' | head -n1)
        [ -n "$cur" ] || cur=$(sed -nE 's/^[[:space:]]*layout[[:space:]]*=[[:space:]]*"([a-z]+)".*/\1/p' "$GENERAL" 2>/dev/null | head -n1)
        if [ "$cur" = "dwindle" ]; then
            target="scrolling"
        elif [ "$cur" = "scrolling" ]; then
            target="off"
        else
            target="dwindle"
        fi
    fi
fi

case "$target" in
    off|floating|float)
        [ -x "$FLOAT_SCRIPT" ] && "$FLOAT_SCRIPT" on
        notify-send "Hyprland Layout" "Switched to Off (Floating - No tiling)" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
        exit 0
        ;;
    scrolling)
        [ -x "$FLOAT_SCRIPT" ] && "$FLOAT_SCRIPT" off
        NEW="scrolling"
        NAME="Scrolling (Niri)"
        ;;
    dwindle|*)
        [ -x "$FLOAT_SCRIPT" ] && "$FLOAT_SCRIPT" off
        NEW="dwindle"
        NAME="Dwindle (Tree)"
        ;;
esac

live=ok
hyprctl eval "hl.config({ general = { layout = \"$NEW\" } })" >/dev/null 2>&1 || live=failed
if [ -w "$GENERAL" ]; then
    sed -i --follow-symlinks -E "s/^([[:space:]]*layout[[:space:]]*=[[:space:]]*)\"[a-z]+\"/\1\"$NEW\"/" "$GENERAL"
fi

if [ "$live" = ok ]; then
    notify-send "Hyprland Layout" "Switched to $NAME layout" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
else
    notify-send "Hyprland Layout" "Could not switch now (hyprctl failed); $NAME is saved for the next start" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
fi
