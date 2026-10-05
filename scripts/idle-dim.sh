#!/usr/bin/env bash
# Dim when you have been away for a while, restore when you come back (called by hypridle: see scripts/idle.sh).
#   idle-dim.sh dim     remember the screen + keyboard-light levels, fade the screen down to its minimum, keyboard light off
#   idle-dim.sh undim   put both back exactly as they were
# The saved levels live in /dev/shm/halcyon-dim (gone after a reboot, so a crash can never leave you stuck dark).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bl="$here/backlight.sh"
flag=/dev/shm/halcyon-dim; fadepid=/dev/shm/halcyon-dim.pid

killfade() { [ -f "$fadepid" ] && kill "$(cat "$fadepid")" 2>/dev/null; rm -f "$fadepid"; }

# fade the screen from $2 to $3 in $4 steps (runs in the background so hypridle is never blocked)
fade() {
  local dev="$1" from="$2" to="$3" steps="$4" i v
  for i in $(seq 1 "$steps"); do
    v=$(( from + (to - from) * i / steps ))
    bash "$bl" set backlight "$dev" "$v"
    sleep 0.05
  done
}

case "$1" in
  dim)
    [ -f "$flag" ] && exit 0                       # already dimmed: do not save the dim level as "normal"
    read -r sdev scur smax <<<"$(bash "$bl" best-screen)"
    {
      [ -n "$sdev" ] && echo "screen $sdev $scur"
      bash "$bl" kbd | while read -r kdev kcur kmax; do echo "kbd $kdev $kcur"; done
    } > "$flag"
    [ -s "$flag" ] || { rm -f "$flag"; exit 0; }
    bash "$bl" kbd | while read -r kdev kcur kmax; do [ "$kcur" -gt 0 ] && bash "$bl" set leds "$kdev" 0; done
    if [ -n "$sdev" ] && [ "$scur" -gt 1 ]; then
      killfade
      ( fade "$sdev" "$scur" 1 8 ) >/dev/null 2>&1 &
      echo $! > "$fadepid"
    fi ;;
  undim)
    killfade
    [ -f "$flag" ] || exit 0
    while read -r kind dev val; do
      case "$kind" in
        screen) bash "$bl" set backlight "$dev" "$val" ;;
        kbd)    bash "$bl" set leds "$dev" "$val" ;;
      esac
    done < "$flag"
    rm -f "$flag" ;;
  *) echo "usage: idle-dim.sh dim | undim" >&2; exit 2 ;;
esac
exit 0
