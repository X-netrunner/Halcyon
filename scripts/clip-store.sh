#!/usr/bin/env bash
# clip-store.sh : what the clipboard watchers run on every copy (autostart-extras.sh / startup-conf.sh):
#     wl-paste --type text  --watch bash clip-store.sh
#     wl-paste --type image --watch bash clip-store.sh
# Controlled via native helper `hal clip-store` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" clip-store "$@"
fi

if [ "${CLIP_GUARD:-1}" != 0 ]; then
  types=$(wl-paste --list-types 2>/dev/null)
  case "${types,,}" in
    *passwordmanagerhint*) cat >/dev/null; exit 0 ;;
  esac
fi
exec cliphist store
