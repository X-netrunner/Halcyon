#!/usr/bin/env bash
# idle-dim.sh [dim | undim]
# Controlled via native helper `hal idle-dim` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" idle-dim "$@"
fi
echo "idle-dim.sh: hal binary not found at $hal" >&2
exit 1
