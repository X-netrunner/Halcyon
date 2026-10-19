#!/usr/bin/env bash
# brightness.sh up|down [percent]   (default step 5)
# Adjust screen brightness via native helper `hal brightness` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" brightness "$@"
fi
echo "brightness.sh: hal binary not found at $hal" >&2
exit 1
