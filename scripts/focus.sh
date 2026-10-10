#!/usr/bin/env bash
# Focus mode (advanced do-not-disturb with a timer and an app block list). See focus.py for what it does.
#   focus.sh start [MINUTES] [pomo] | stop | toggle | pause | resume | add MIN | skip | status | conf | set KEY VAL | apps | block CLASS | unblock CLASS
exec python3 "$(dirname "$(readlink -f "$0")")/focus.py" "$@"
