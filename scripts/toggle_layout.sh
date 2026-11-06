#!/bin/bash
# SUPER+ALT+T: toggle the Hyprland layout between dwindle, scrolling (niri style), and off (floating).
# general.lua is the source of truth for tiling, and floating-mode.sh manages off/floating mode.
GENERAL="$HOME/.config/Halcyon/hyprland/general.lua"
FLOAT_SCRIPT="$HOME/.config/Halcyon/scripts/floating-mode.sh"
PROFILE_SCRIPT="$HOME/.config/Halcyon/scripts/gesture-profile.sh"
# floating-mode.sh syncs the gesture profile itself, but "No tiling" leaves layout = "scrolling" in general.lua underneath, so
# turning it off in the middle of a switch would look like niri for a moment (a pointless reload). This script syncs once, at the end.
export HALCYON_SKIP_PROFILE_SYNC=1
resync() { [ -x "$PROFILE_SCRIPT" ] && "$PROFILE_SCRIPT" sync; }

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
        resync
        notify-send -a Halcyon "Hyprland Layout" "Switched to Off (Floating - No tiling)" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
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
# scrolling (niri) layout: the off-screen columns sit where the next workspace slides in from and showed up as a ghost for a moment,
# so workspaces slide up / down there (hyprland/animations.lua picks the same on a reload)
if [ "$NEW" = "scrolling" ]; then WS_STYLE=slidevert; else WS_STYLE=slide; fi
hyprctl eval "hl.animation({ leaf = \"workspaces\", enabled = true, speed = 6, bezier = \"glide\", style = \"$WS_STYLE\" })" >/dev/null 2>&1 || true
if [ -w "$GENERAL" ]; then
    sed -i --follow-symlinks -E "s/^([[:space:]]*layout[[:space:]]*=[[:space:]]*)\"[a-z]+\"/\1\"$NEW\"/" "$GENERAL"
fi

# the 4-finger gestures point up / down in the scrolling layout and left / right everywhere else: when the saved layout moved to the
# other kind, Hyprland reads the config again (general.lua is written just above, which is what that reload reads). Skipped when
# general.lua could not be written, because a reload would then put the old layout back.
[ -w "$GENERAL" ] && resync

if [ "$live" = ok ]; then
    notify-send -a Halcyon "Hyprland Layout" "Switched to $NAME layout" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
else
    notify-send -a Halcyon "Hyprland Layout" "Could not switch now (hyprctl failed); $NAME is saved for the next start" -i preferences-desktop-theme -h string:x-canonical-private-synchronous:hypr_layout
fi
