#!/usr/bin/env bash
# notif-guard.sh: terminate competing notification daemons before island starts
# Controlled via native helper `hal notif-guard` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" notif-guard "$@"
fi
echo "notif-guard.sh: hal binary not found at $hal" >&2
exit 1
