#!/usr/bin/env bash
# Started by Hyprland (hyprland/execs.lua). Only does something when Halcyon was started by launch/halcyon-login.sh
# Controlled via native helper `hal login-watchdog` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" login-watchdog "$@"
fi

flag="$HOME/.cache/island/lock-on-start"
[ -f "$flag" ] || exit 0

submap() { hyprctl dispatch "hl.dsp.submap(\"$1\")" >/dev/null 2>&1 || true; }
submap halcyon-locking
trap 'submap reset' EXIT
for _ in $(seq 1 20); do
  sleep 1
  if [ ! -f "$flag" ]; then sleep 2; exit 0; fi
done
rm -f "$flag"
if command -v hyprlock >/dev/null 2>&1 && hyprlock; then exit 0; fi
hyprctl dispatch "hl.dsp.exit()" >/dev/null 2>&1 || pkill -x Hyprland
