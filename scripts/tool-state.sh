#!/usr/bin/env bash
# What is switched on right now, as one line of JSON. Settings > Tools reads it so its switches always show the truth
# (also when something was toggled with a key, from a terminal, or the script failed).
# (edge gestures are off while /dev/shm/touchpad_music_gestures_disabled exists, see toggle_gestures.sh)
#   {"nightlight":false,"nightlightOk":true,"touchpad":true,"gestures":true,"wifips":false,"wifiOk":true,"temp":4000}
nl=false; pgrep -x hyprsunset >/dev/null 2>&1 && nl=true
ok=false; command -v hyprsunset >/dev/null 2>&1 && ok=true
tp=true; [ "$(head -n1 "${XDG_RUNTIME_DIR:-/tmp}/touchpad.status" 2>/dev/null)" = disabled ] && tp=false
ge=true; [ -f /dev/shm/touchpad_music_gestures_disabled ] && ge=false
# Wi-Fi power saving: ask the driver (iw needs no root for this); no wireless card = the switch is shown but does nothing
wo=false; wp=false
if command -v iw >/dev/null 2>&1; then
  for d in $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'); do
    wo=true
    iw dev "$d" get power_save 2>/dev/null | grep -qi 'power save: *on' && wp=true
  done
fi
t=$(head -n1 "$HOME/.local/state/island/nightlight-temp" 2>/dev/null)
case "$t" in ''|*[!0-9]*) t=4000 ;; esac
printf '{"nightlight":%s,"nightlightOk":%s,"touchpad":%s,"gestures":%s,"wifips":%s,"wifiOk":%s,"temp":%s}\n' "$nl" "$ok" "$tp" "$ge" "$wp" "$wo" "$t"
