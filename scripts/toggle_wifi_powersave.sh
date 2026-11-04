#!/usr/bin/env bash
# toggle_wifi_powersave.sh [on | off | toggle | status | apply]
# Controlled via native helper `hal wifips` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" wifips "$@"
fi
echo "toggle_wifi_powersave.sh: hal binary not found at $hal" >&2
exit 1
