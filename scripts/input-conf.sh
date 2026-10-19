#!/usr/bin/env bash
# input-conf.sh conf | mice | set ID ACTION [CMD] | reset [gestures|mouse|all] | run ID
# Touchpad gestures and mouse buttons configuration via native helper `hal input` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" input "$@"
fi
echo "input-conf.sh: hal binary not found at $hal" >&2
exit 1
