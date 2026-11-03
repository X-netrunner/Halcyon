#!/bin/bash
# SUPER+PERIOD: emoji picker in fuzzel, copies the chosen emoji to the clipboard (needs bemoji).
# Native helper first: `hal emoji` (src/hal). Exit 2 = an older hal that does not know it yet: the bash below still works.
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  "$hal" emoji "$@" && exit 0; rc=$?
  [ "$rc" -ne 2 ] && exit "$rc"
fi
if ! command -v bemoji >/dev/null; then
    notify-send -a Halcyon "Emoji picker" "bemoji is not installed (AUR: bemoji)" -i dialog-warning
    exit 1
fi
export BEMOJI_PICKER_CMD="fuzzel --dmenu --prompt=Emoji>\  --width=40 --lines=12"
exec bemoji -c
