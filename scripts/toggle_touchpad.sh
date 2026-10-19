#!/usr/bin/env bash
# toggle_touchpad.sh [toggle | status]
# Controlled via native helper `hal touchpad` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" touchpad "$@"
fi
echo "toggle_touchpad.sh: hal binary not found at $hal" >&2
exit 1
