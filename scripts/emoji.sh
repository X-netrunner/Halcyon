#!/bin/bash
# SUPER+PERIOD: emoji picker in fuzzel, copies the chosen emoji to the clipboard (needs bemoji).
if ! command -v bemoji >/dev/null; then
    notify-send "Emoji picker" "bemoji is not installed (AUR: bemoji)" -i dialog-warning
    exit 1
fi
export BEMOJI_PICKER_CMD="fuzzel --dmenu --prompt=Emoji>\  --width=40 --lines=12"
exec bemoji -c
