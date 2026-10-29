#!/usr/bin/env bash
# SUPER+SHIFT+S: freeze the screen (wayfreeze, if installed), drag a region, save it to
# ~/Pictures/Screenshots and copy it to the clipboard.
# Controlled via native helper `hal screenshot-area` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" screenshot-area "$@"
fi

dir="$HOME/Pictures/Screenshots"
mkdir -p "$dir"
file="$dir/$(date +%s).png"

freeze=""
if command -v wayfreeze >/dev/null; then
    wayfreeze >/dev/null 2>&1 &
    freeze=$!
    sleep 0.2
fi

geom=$(slurp -d 2>/dev/null)
if [ -n "$geom" ] && grim -g "$geom" "$file"; then
    [ -n "$freeze" ] && kill "$freeze" 2>/dev/null
    wl-copy < "$file"
    notify-send "Screenshot" "Saved and copied" -i "$file" -h string:x-canonical-private-synchronous:screenshot
else
    [ -n "$freeze" ] && kill "$freeze" 2>/dev/null
fi
