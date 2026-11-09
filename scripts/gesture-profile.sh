#!/usr/bin/env bash
# gesture-profile.sh [profile | sync]
#
# The 4-finger gestures point differently in the scrolling (niri) layout than in dwindle / no tiling (hyprland/inputconf.lua
# turns them, hyprland/gestures.lua registers them). Hyprland only registers gestures when the config is read, so when the
# layout moves from one profile to the other the config has to be read again.
#
#   profile   print "niri" or "other" for the layout that is saved right now
#   sync      reload Hyprland when that differs from the profile gestures.lua registered last (it leaves it in
#             ~/.local/state/island/gesture-profile). Changing dwindle <-> no tiling changes nothing, so nothing is reloaded.
#
# Called by toggle_layout.sh and floating-mode.sh after they change the layout. The logic of `profile` is the same as
# detect_niri() in hyprland/inputconf.lua: keep the two in step.
STATE="$HOME/.local/state/island"
GENERAL="$HOME/.config/Halcyon/hyprland/general.lua"
STAMP="$STATE/gesture-profile"

profile() {
    # "No tiling" keeps layout = "scrolling" in general.lua underneath, so the flag wins
    if [ "$(head -n1 "$STATE/float-all" 2>/dev/null)" = "1" ]; then echo other; return; fi
    local layout
    layout=$(sed -nE 's/^[[:space:]]*layout[[:space:]]*=[[:space:]]*"([a-z]+)".*/\1/p' "$GENERAL" 2>/dev/null | head -n1)
    if [ "$layout" = "scrolling" ]; then echo niri; else echo other; fi
}

case "${1:-sync}" in
    profile)
        profile
        ;;
    sync)
        now=$(profile)
        last=$(head -n1 "$STAMP" 2>/dev/null)
        # no stamp yet = gestures were registered before this existed, and then they were always the "other" kind
        [ -n "$last" ] || last=other
        [ "$now" = "$last" ] || hyprctl reload >/dev/null 2>&1
        exit 0
        ;;
    *)
        echo "usage: gesture-profile.sh [profile|sync]" >&2
        exit 2
        ;;
esac
