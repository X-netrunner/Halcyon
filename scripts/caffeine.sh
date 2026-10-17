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
  # minutes: a whole number above 0 (a typo used to end in the misleading "is systemd-run available?" message)
  local mins=""
  if [ -n "$1" ]; then
    case "$1" in *[!0-9]*) echo "caffeine: minutes must be a whole number, e.g. caffeine.sh on 30" >&2; return 2 ;; esac
    [ "${#1}" -le 6 ] && mins=$((10#$1))
    [ -n "$mins" ] && [ "$mins" -gt 0 ] || { echo "caffeine: minutes must be between 1 and 999999" >&2; return 2; }
  fi
  if is_on; then
    # already on: a new length (or "until I turn it off" after a timed run) replaces the running one; the same request does nothing
    local cur; cur=$(systemctl --user show -p RuntimeMaxUSec --value "$UNIT" 2>/dev/null)
    if [ -z "$mins" ] && { [ -z "$cur" ] || [ "$cur" = infinity ]; }; then return 0; fi
    systemctl --user stop "$UNIT" 2>/dev/null
  fi
  local extra=()
  [ -n "$mins" ] && extra=(--property="RuntimeMaxSec=${mins}m")
  systemd-run --user --quiet --collect --unit="${UNIT%.service}" "${extra[@]}" \
    systemd-inhibit --what=idle:sleep --who=Halcyon --why="Caffeine" --mode=block sleep infinity \
    && { echo on > "$STATE"; note "On${mins:+ for $mins min}: screen stays awake"; } \
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
