#!/usr/bin/env bash
# Caffeine: while on, the screen does not dim, hypridle does not lock, and the machine does not idle-suspend.
#   caffeine.sh on [minutes] | off | toggle | status
# Controlled via native helper `hal caffeine` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" caffeine "$@"
fi
echo "caffeine.sh: hal binary not found at $hal" >&2
exit 1
