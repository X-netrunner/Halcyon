#!/usr/bin/env bash
# Lock the screen with Halcyon's own lock screen (quickshell/island/Lock.qml).
# Falls back to hyprlock if the island is not running, so you can never end up unable to lock.
# Use it as hypridle's lock_cmd:   general { lock_cmd = ~/.config/Halcyon/scripts/lock.sh }
# Native helper first: `hal lock` (src/hal). Exit 2 = an older hal that does not know it yet: the bash below still works.
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  "$hal" lock "$@" && exit 0; rc=$?
  [ "$rc" -ne 2 ] && exit "$rc"
fi
if timeout 2 quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island lock >/dev/null 2>&1; then
  exit 0
fi
command -v hyprlock >/dev/null && exec hyprlock
notify-send -a Halcyon "Lock screen" "The island is not running and hyprlock is not installed" 2>/dev/null
exit 1
