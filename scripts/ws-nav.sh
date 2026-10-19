#!/usr/bin/env bash
# ws-nav.sh next | prev | gesture-right | gesture-left | gesture4-right | gesture4-left | wheel-up | wheel-down
# Workspace navigation via native helper `hal wsnav` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" wsnav "$@"
fi
echo "ws-nav.sh: hal binary not found at $hal" >&2
exit 1
