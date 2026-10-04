#!/usr/bin/env bash
# brightness.sh up|down [percent]   (default step 5)
# Used by the top-edge touchpad gesture (a systemd user service), which is NOT inside your login session, so a plain
# `brightnessctl` often cannot write the backlight there. This tries, in order:
#   1. brightnessctl                      works if you are in the `video` group (udev rule) or logind accepts the call
#   2. a direct write to sysfs             works if the backlight file is writable
#   3. logind SetBrightness over D-Bus     what brightnessctl does inside a session, with your session named explicitly
# Failures are printed to stderr:  journalctl --user -u touchpad-gestures -e
dir="${1:-up}"; step="${2:-5}"
case "$dir" in up) arg="${step}%+" ;; down) arg="${step}%-" ;; *) echo "usage: brightness.sh up|down [percent]" >&2; exit 2 ;; esac

if command -v brightnessctl >/dev/null && brightnessctl -q --min-value=1 set "$arg" 2>/dev/null; then exit 0; fi

# pick the backlight with the biggest range (same rule as `hx ctl`)
best=""; bmax=0
for d in /sys/class/backlight/*; do
  [ -r "$d/max_brightness" ] || continue
  m=$(cat "$d/max_brightness"); [ "$m" -gt "$bmax" ] && { bmax=$m; best=$d; }
done
[ -n "$best" ] || { echo "brightness.sh: no backlight device in /sys/class/backlight" >&2; exit 1; }
dev=$(basename "$best"); cur=$(cat "$best/brightness")
delta=$(( bmax * step / 100 )); [ "$delta" -lt 1 ] && delta=1
if [ "$dir" = up ]; then new=$(( cur + delta )); else new=$(( cur - delta )); fi
[ "$new" -gt "$bmax" ] && new=$bmax
[ "$new" -lt 1 ] && new=1

if [ -w "$best/brightness" ]; then echo "$new" > "$best/brightness" && exit 0; fi

sess=$(loginctl show-user "$USER" -p Display --value 2>/dev/null)
[ -n "$sess" ] || sess=auto
if busctl call org.freedesktop.login1 "/org/freedesktop/login1/session/$sess" org.freedesktop.login1.Session SetBrightness ssu backlight "$dev" "$new" >/dev/null 2>&1; then exit 0; fi

echo "brightness.sh: cannot change brightness. Add yourself to the video group: sudo usermod -aG video \$USER (then log in again)" >&2
exit 1
