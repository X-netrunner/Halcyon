#!/usr/bin/env bash
# Focus mode (advanced do-not-disturb with a timer and an app block list). See focus.py / src/hx/src/focus.rs for what it does.
#   focus.sh start [MINUTES] [pomo] | stop | toggle | pause | resume | add MIN | skip | status | conf | set KEY VAL | apps | block CLASS [CLASS...] | unblock CLASS
# The native helper (`hx focus`, built by install.sh) is used when this build of hx has it; otherwise the Python version
# (focus.py) does the same job, so nothing breaks before the helpers are rebuilt.
here="$(dirname "$(readlink -f "$0")")"
hx="$here/../bin/hx"; [ -x "$hx" ] || hx="$HOME/.config/Halcyon/bin/hx"
if [ -x "$hx" ] && "$hx" focus ping >/dev/null 2>&1; then
  exec "$hx" focus "$@"
fi
exec python3 "$here/focus.py" "$@"
