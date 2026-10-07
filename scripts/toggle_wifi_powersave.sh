#!/usr/bin/env bash
# Wi-Fi power saving:  toggle_wifi_powersave.sh [on | off | toggle | status]     (default: toggle)
# on = saves battery, off = lowest latency. Run from Settings > Tools. The change itself is made by the root helper
# halcyon-tune through sudo, which install.sh sets up without a password prompt (nothing can be typed here: the island has
# no terminal), so run install.sh again if this says it could not change it.
HELPER=/usr/local/bin/halcyon-tune
note() { command -v notify-send >/dev/null && notify-send -a Halcyon -i network-wireless -h string:x-canonical-private-synchronous:wifips "Wi-Fi power saving" "$1"; }

is_on() {   # 0 = at least one wireless interface has power saving on
  command -v iw >/dev/null 2>&1 || return 1
  local d
  for d in $(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }'); do
    iw dev "$d" get power_save 2>/dev/null | grep -qi 'power save: *on' && return 0
  done
  return 1
}

case "${1:-toggle}" in
  status) is_on && echo on || echo off; exit 0 ;;
  on|off) want=$1 ;;
  toggle) if is_on; then want=off; else want=on; fi ;;
  *) echo "usage: toggle_wifi_powersave.sh [on|off|toggle|status]" >&2; exit 2 ;;
esac

command -v iw >/dev/null 2>&1 || { note "iw is not installed (pacman -S iw)"; exit 1; }
if timeout 6 sudo -n "$HELPER" wifi-ps "$want" 2>/dev/null; then
  if [ "$want" = on ]; then note "On: saves battery"; else note "Off: lowest latency"; fi
else
  note "Could not change it: run install.sh again (it sets up the helper that is allowed to do this)"
  exit 1
fi
