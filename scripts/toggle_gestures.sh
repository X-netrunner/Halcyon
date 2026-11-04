#!/usr/bin/env bash
# toggle_gestures.sh [toggle | status]
# Controlled via native helper `hal gestures` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" gestures "$@"
fi
echo "toggle_gestures.sh: hal binary not found at $hal" >&2
exit 1
