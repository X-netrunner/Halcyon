#!/usr/bin/env bash
# Live tool toggles JSON state (nightlight, touchpad, gestures, wifips, temp)
# Read via native helper `hal tool-state` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" tool-state "$@"
fi
echo "tool-state.sh: hal binary not found at $hal" >&2
exit 1
