#!/usr/bin/env bash
# Caffeine: while on, the screen does not dim, hypridle does not lock, and the machine does not idle-suspend.
#   caffeine.sh on [minutes]   start (no minutes = until you turn it off)
#   caffeine.sh off | toggle | status
# It is a systemd-inhibit lock held by a transient user unit (halcyon-caffeine.service), so stopping the unit
# releases everything, and it also goes away by itself on log out / reboot. hypridle honours it
# (`ignore_systemd_inhibit` must not be set to true in hypridle.conf).
UNIT=halcyon-caffeine.service
STATE=/dev/shm/halcyon-caffeine

is_on() { systemctl --user is-active --quiet "$UNIT"; }
note() { command -v notify-send >/dev/null && ( timeout 3 notify-send -a Halcyon -i weather-clear -t 2500 "Caffeine" "$1" >/dev/null 2>&1 & ); }

on() {
  is_on && return 0
  local extra=()
  [ -n "$1" ] && extra=(--property="RuntimeMaxSec=${1}m")
  systemd-run --user --quiet --collect --unit="${UNIT%.service}" "${extra[@]}" \
    systemd-inhibit --what=idle:sleep --who=Halcyon --why="Caffeine" --mode=block sleep infinity \
    && { echo on > "$STATE"; note "On${1:+ for $1 min}: screen stays awake"; } \
    || echo "caffeine: could not start (is systemd-run / systemd-inhibit available?)" >&2
}
off() {
  systemctl --user stop "$UNIT" 2>/dev/null
  rm -f "$STATE"
  note "Off"
}

case "${1:-toggle}" in
  on)     on "$2" ;;
  off)    off ;;
  toggle) if is_on; then off; else on "$2"; fi ;;
  status) if is_on; then echo on; else echo off; rm -f "$STATE"; fi ;;
  *) echo "usage: caffeine.sh on [minutes] | off | toggle | status" >&2; exit 2 ;;
esac
