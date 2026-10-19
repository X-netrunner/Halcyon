#!/usr/bin/env bash
# numlock.sh [status | toggle | on | off]
# Controlled via native helper `hal numlock` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" numlock "$@"
fi
echo "numlock.sh: hal binary not found at $hal" >&2
exit 1
