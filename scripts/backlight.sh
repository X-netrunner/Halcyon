#!/usr/bin/env bash
# backlight.sh set <class> <device> <raw>      class = backlight (screen) | leds (keyboard light)
# backlight.sh best-screen                     prints "device cur max" of the screen backlight with the biggest range
# backlight.sh kbd                             prints "device cur max" for every keyboard backlight found
# Writes one brightness value the way that works for the caller. Tried in order:
#   1. brightnessctl          (video / input group + its udev rule, or logind)
#   2. a direct sysfs write   (when the file is writable, e.g. after the Halcyon udev rule)
#   3. logind SetBrightness   (D-Bus; needs no group at all inside a normal login session)
# This is the "driver" layer for the screen and the keyboard light: the kernel driver (acpi_video, intel/amdgpu backlight,
# asus-wmi, thinkpad_acpi, dell-laptop, ...) creates the sysfs device, this script only talks to it.
best_screen() {
  local best="" bmax=0 m d
  for d in /sys/class/backlight/*; do
    [ -r "$d/max_brightness" ] || continue
    m=$(cat "$d/max_brightness"); [ "$m" -gt "$bmax" ] && { bmax=$m; best=$d; }
  done
  [ -n "$best" ] && echo "$(basename "$best") $(cat "$best/brightness") $bmax"
}
kbd_list() {
  local d
  for d in /sys/class/leds/*kbd_backlight* /sys/class/leds/*kbd-backlight* /sys/class/leds/*keyboard*backlight*; do
    [ -r "$d/max_brightness" ] || continue
    echo "$(basename "$d") $(cat "$d/brightness") $(cat "$d/max_brightness")"
  done | sort -u
}
case "$1" in
  best-screen) best_screen ;;
  kbd) kbd_list ;;
  set)
    class="$2"; dev="$3"; val="$4"
    case "$class" in backlight|leds) ;; *) echo "class must be backlight or leds" >&2; exit 2 ;; esac
    [ -n "$dev" ] && [ -n "$val" ] || { echo "usage: backlight.sh set <class> <device> <raw>" >&2; exit 2; }
    if command -v brightnessctl >/dev/null && brightnessctl -q -c "$class" -d "$dev" set "$val" >/dev/null 2>&1; then exit 0; fi
    f="/sys/class/$class/$dev/brightness"
    if [ -w "$f" ] && echo "$val" > "$f" 2>/dev/null; then exit 0; fi
    sess=$(loginctl show-user "$USER" -p Display --value 2>/dev/null); [ -n "$sess" ] || sess=auto
    if busctl call org.freedesktop.login1 "/org/freedesktop/login1/session/$sess" org.freedesktop.login1.Session SetBrightness ssu "$class" "$dev" "$val" >/dev/null 2>&1; then exit 0; fi
    echo "backlight.sh: cannot write $class/$dev. Run: scripts/kbd-backlight.sh doctor   (groups input + video, udev rule)" >&2
    exit 1 ;;
  *) echo "usage: backlight.sh set <backlight|leds> <device> <raw> | best-screen | kbd" >&2; exit 2 ;;
esac
