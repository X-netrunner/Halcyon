#!/usr/bin/env bash
# Cool mode: on | off | toggle | status. The root side is halcyon-tune cool-on / cool-off.
STATE_DIR="$HOME/.local/state/island"; mkdir -p "$STATE_DIR"
note() { command -v notify-send >/dev/null && notify-send -a Halcyon -i temperature-cold "Cool mode" "$1" -h string:x-canonical-private-synchronous:coolmode; }
is_on() { [ -f /run/halcyon-cool.saved ]; }

case "${1:-toggle}" in
  on|off) want="$1" ;;
  toggle) is_on && want=off || want=on ;;
  status) is_on && echo on || echo off; exit 0 ;;
  *) echo "usage: cool.sh on|off|toggle|status" >&2; exit 2 ;;
esac

if ! timeout 20 sudo -n /usr/local/bin/halcyon-tune "cool-$want" 2>"$STATE_DIR/cool-error"; then
  note "Could not switch: $(tail -1 "$STATE_DIR/cool-error" 2>/dev/null || echo 'run install.sh again to set up halcyon-tune')"
  exit 1
fi
if [ "$want" = on ]; then
  note "On: turbo off and the CPU capped at 70 %, so it runs cooler and quieter"
else
  note "Off: full speed again"
fi
