#!/usr/bin/env bash
# extra-dim.sh: Toggle or set Extra Dim mode (drops screen backlight to minimum)
#   extra-dim.sh toggle | on | off | status
# Controlled via native helper `hal extra-dim` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" extra-dim "$@"
fi
echo "extra-dim.sh: hal binary not found at $hal" >&2
exit 1
