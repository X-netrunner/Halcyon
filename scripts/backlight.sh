#!/usr/bin/env bash
# backlight.sh set <backlight|leds> <device> <raw> | best-screen | kbd
# Driver layer for screen and keyboard light via native helper `hal backlight` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" backlight "$@"
fi
echo "backlight.sh: hal binary not found at $hal" >&2
exit 1
