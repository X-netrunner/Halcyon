#!/bin/sh
# SUPER+Q: close top-most island overlay or active window.
# Controlled via native helper `hal close` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  "$hal" close "$@"; rc=$?
  [ "$rc" -ne 2 ] && exit "$rc"      # 2 = this hal is older than the script and does not know `close`: use the plain version below
fi
r=$(quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island closeTop 2>/dev/null)
[ "$r" = "closed" ] && exit 0
exec hyprctl dispatch 'hl.dsp.window.close()'
