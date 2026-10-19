#!/usr/bin/env bash
# toggle_nightlight.sh [on | off | toggle | temp <K> | status]
# Controlled via native helper `hal nightlight` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" nightlight "$@"
fi
echo "toggle_nightlight.sh: hal binary not found at $hal" >&2
exit 1
