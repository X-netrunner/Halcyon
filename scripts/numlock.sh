#!/usr/bin/env bash
# Num Lock: read it, flip it (the bar builder widget "Num lock").
#   numlock.sh status   prints  on | off
#   numlock.sh toggle   presses the Num Lock key and checks that it changed
#   numlock.sh on | off set it (presses the key only when it is in the other state)
# Reading: Hyprland's main keyboard (hyprctl devices), or the keyboard's Num Lock LED when Hyprland does not answer.
# Pressing: ydotool (needs its daemon: systemctl --user enable --now ydotool), or wtype as a second try.
note() { command -v notify-send >/dev/null && ( timeout 3 notify-send -a Halcyon -i input-keyboard -t 3500 "Num Lock" "$1" >/dev/null 2>&1 & ); }

status() {
  local s=""
  if command -v hyprctl >/dev/null 2>&1; then
    s=$(hyprctl devices -j 2>/dev/null | awk '
      /"numLock"/ { n = ($0 ~ /true/) ? "on" : "off" }
      /"main": *true/ { print n; done = 1; exit }
      END { if (!done && n != "") print n }')
  fi
  if [ -z "$s" ]; then
    local f v
    for f in /sys/class/leds/*::numlock/brightness; do
      [ -r "$f" ] || continue
      read -r v < "$f"
      [ "$v" != "0" ] && s=on || s=off
      break
    done
  fi
  echo "${s:-off}"
}

press() {
  if command -v ydotool >/dev/null 2>&1 && ydotool key 69:1 69:0 >/dev/null 2>&1; then return 0; fi   # 69 = KEY_NUMLOCK
  if command -v wtype >/dev/null 2>&1 && wtype -k Num_Lock >/dev/null 2>&1; then return 0; fi
  return 1
}

flip() {
  local before after
  before=$(status)
  if ! press; then
    note "Could not press the key: install ydotool and run  systemctl --user enable --now ydotool"
    return 1
  fi
  sleep 0.25
  after=$(status)
  [ "$after" != "$before" ] || { note "The key was sent but Num Lock did not change (ydotool needs its daemon running)"; return 1; }
}

case "${1:-toggle}" in
  status) status ;;
  toggle) flip ;;
  on)     [ "$(status)" = on ] || flip ;;
  off)    [ "$(status)" = off ] || flip ;;
  *) echo "usage: numlock.sh status | toggle | on | off" >&2; exit 2 ;;
esac
