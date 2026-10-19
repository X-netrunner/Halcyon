#!/bin/sh
# Tap Super alone -> open / close the launcher.
# Controlled via native helper `hal supertap` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" supertap "$@"
fi
f="${XDG_RUNTIME_DIR:-/tmp}/halcyon-super-tap"
printf '%s\n' "$$" > "$f" 2>/dev/null && exit 0
exec quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island supertap >/dev/null 2>&1
