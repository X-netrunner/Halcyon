#!/bin/bash
# Started by Hyprland (hyprland/execs.lua). Only does something when Halcyon was started by launch/halcyon-login.sh:
# the island must take ~/.cache/island/lock-on-start (and so lock the screen) within 20 seconds. If it never does, the
# desktop would be sitting there open with nobody logged in, so lock with hyprlock, or failing that end the session.
flag="$HOME/.cache/island/lock-on-start"
[ -f "$flag" ] || exit 0
for _ in $(seq 1 20); do
  sleep 1
  [ -f "$flag" ] || exit 0                  # the island took it: it is locking
done
rm -f "$flag"
if command -v hyprlock >/dev/null 2>&1 && hyprlock; then exit 0; fi
hyprctl dispatch "hl.dsp.exit()" >/dev/null 2>&1 || pkill -x Hyprland
