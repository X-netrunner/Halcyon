#!/usr/bin/env bash
# Keeps floating windows (Picture-in-Picture, pop-ups) out of the screen border and the bar: `hal keep-clear` moves one that was
# dragged over them back into the free area. Off with:  echo 0 > ~/.local/state/island/keep-clear   (1 = on again)
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
[ -x "$hal" ] || exit 0
exec "$hal" keep-clear
