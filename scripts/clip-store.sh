#!/usr/bin/env bash
# clip-store.sh : what the clipboard watchers run on every copy (autostart-extras.sh / startup-conf.sh):
#     wl-paste --type text  --watch bash clip-store.sh
#     wl-paste --type image --watch bash clip-store.sh
# wl-paste hands the new clipboard content on stdin. It goes to `cliphist store`, EXCEPT when the app that copied it says it is a
# secret: password managers (KeePassXC, Bitwarden, 1Password, Proton Pass ...) add the type "x-kde-passwordManagerHint" to a
# password they put on the clipboard. Those are dropped here and never reach the history file. Set CLIP_GUARD=0 to turn this off.
if [ "${CLIP_GUARD:-1}" != 0 ]; then
  types=$(wl-paste --list-types 2>/dev/null)
  case "${types,,}" in
    *passwordmanagerhint*) cat >/dev/null; exit 0 ;;
  esac
fi
exec cliphist store
