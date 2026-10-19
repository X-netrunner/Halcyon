#!/bin/bash
# Started by Hyprland (hyprland/execs.lua). Only does something when Halcyon was started by launch/halcyon-login.sh:
# the island must take ~/.cache/island/lock-on-start (and so lock the screen) within 20 seconds. If it never does, the
# desktop would be sitting there open with nobody logged in, so lock with hyprlock, or failing that end the session.
flag="$HOME/.cache/island/lock-on-start"
[ -f "$flag" ] || exit 0
# Until the lock is up, the desktop is open and every shortcut would work (a terminal, the launcher ...). An empty Hyprland submap
# (defined at the end of hyprland/keybinds.lua) has no binds at all, so no key does anything until the lock screen takes over.
# It is always put back on the way out, whichever way the loop below ends.
submap() { hyprctl dispatch "hl.dsp.submap(\"$1\")" >/dev/null 2>&1 || true; }
submap halcyon-locking
trap 'submap reset' EXIT
for _ in $(seq 1 20); do
  sleep 1
  if [ ! -f "$flag" ]; then sleep 2; exit 0; fi   # the island took it: it is locking (2 s more for the lock surface to appear, then the trap hands the keys back)
done
rm -f "$flag"
if command -v hyprlock >/dev/null 2>&1 && hyprlock; then exit 0; fi
hyprctl dispatch "hl.dsp.exit()" >/dev/null 2>&1 || pkill -x Hyprland
