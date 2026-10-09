#!/usr/bin/env bash
# Watches the screen brightness and the keyboard light and prints one JSON line when either changes:
#   {"k":"bright","p":63}     {"k":"kbd","p":50}
# The island (Osd.qml) turns those into the slide-in bar. Works no matter WHO changed it: the brightness keys, the touchpad
# edge gesture, the panel slider, another app. (Volume is watched by the island itself through `pactl subscribe`.)
# Silent while the idle dim is active, and for a moment after it ends, so dimming and waking up never pop the bar.
shopt -s nullglob
screen=""; bmax=0
for d in /sys/class/backlight/*; do
  [ -r "$d/max_brightness" ] || continue
  m=$(<"$d/max_brightness"); [ "$m" -gt "$bmax" ] && { bmax=$m; screen=$d; }
done
kbd=""; kmax=0
for d in /sys/class/leds/*kbd_backlight* /sys/class/leds/*kbd-backlight*; do
  [ -r "$d/max_brightness" ] && { kbd=$d; kmax=$(<"$d/max_brightness"); break; }
done
[ -n "$screen" ] || [ -n "$kbd" ] || exit 0
# wait without starting a `sleep` process: a timed read on a pipe nobody writes to
exec {nap}<> <(:)
lb=-1; lk=-1; quiet=0
while :; do
  if [ -e /dev/shm/halcyon-dim ]; then quiet=8
  elif [ "$quiet" -gt 0 ]; then quiet=$((quiet - 1)); fi
  if [ -n "$screen" ]; then
    read -r b < "$screen/brightness" 2>/dev/null || b=$lb
    if [ "$b" != "$lb" ]; then
      [ "$lb" != -1 ] && [ "$quiet" -eq 0 ] && printf '{"k":"bright","p":%d}\n' $(( b * 100 / bmax ))
      lb=$b
    fi
  fi
  if [ -n "$kbd" ]; then
    read -r k < "$kbd/brightness" 2>/dev/null || k=$lk
    if [ "$k" != "$lk" ]; then
      [ "$lk" != -1 ] && [ "$quiet" -eq 0 ] && printf '{"k":"kbd","p":%d}\n' $(( k * 100 / kmax ))
      lk=$k
    fi
  fi
  read -r -t 0.25 -u "$nap" _
done
