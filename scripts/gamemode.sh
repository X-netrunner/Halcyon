#!/usr/bin/env bash
# Gaming mode: on | off | toggle | status.  Run by the island (Gaming chip / Settings / SUPER+F10).
#   on   performance power profile (Auto power paused), Hyprland animations / blur / shadows / gaps / rounding off,
#        a short list of background helpers stopped (see below). The island itself switches to instant animations.
#   off  power profile and Auto power back as they were, Hyprland config reloaded.
# Edit ~/.config/Halcyon/gamemode.conf to choose what gets stopped:
#   KILL="cava baloo_file baloo_file_extractor tracker-miner-fs-3 tracker-extract-3"   # processes killed by name (never restarted)
#   STOP_SERVICES=""                                                                  # user services stopped now, started again on `off`
# Nothing security related (sysmode, honeypot, IDS) is ever touched.
STATE=/dev/shm/halcyon-gamemode
CONF="$HOME/.config/Halcyon/gamemode.conf"
KILL="cava baloo_file baloo_file_extractor tracker-miner-fs-3 tracker-extract-3"
STOP_SERVICES=""
[ -f "$CONF" ] && . "$CONF"

# never block on the notification daemon (that is the island itself) or on hyprctl: run them in the background / with a timeout
note() { command -v notify-send >/dev/null && ( timeout 3 notify-send -a Halcyon -i applications-games -t 3000 "Gaming mode" "$1" >/dev/null 2>&1 & ); }
hl() { timeout 4 hyprctl "$@" >/dev/null 2>&1; }

on() {
  [ -f "$STATE" ] && return 0     # already on
  prof=$(powerprofilesctl get 2>/dev/null || echo balanced)
  auto=no; systemctl --user is-active --quiet power-manager.service && auto=yes
  { echo "profile=$prof"; echo "auto=$auto"; echo "stopped=$(for s in $STOP_SERVICES; do systemctl --user is-active --quiet "$s" && printf '%s ' "$s"; done)"; } > "$STATE"
  timeout 4 systemctl --user stop power-manager.service 2>/dev/null
  timeout 4 powerprofilesctl set performance 2>/dev/null
  hl eval "hl.config({ animations = { enabled = false }, decoration = { blur = { enabled = false }, shadow = { enabled = false }, rounding = 0, dim_inactive = false }, general = { gaps_in = 0, gaps_out = 0 } })"
  for s in $STOP_SERVICES; do systemctl --user stop "$s" 2>/dev/null; done
  for p in $KILL; do pkill -x "$p" 2>/dev/null; done
  note "On: performance profile, effects off, helpers stopped"
}

off() {
  [ -f "$STATE" ] || return 0
  . "$STATE"
  rm -f "$STATE"
  timeout 4 powerprofilesctl set "${profile:-balanced}" 2>/dev/null
  [ "$auto" = yes ] && timeout 4 systemctl --user start power-manager.service 2>/dev/null
  for s in $stopped; do systemctl --user start "$s" 2>/dev/null; done
  hl reload
  note "Off: everything back as it was"
}

case "${1:-toggle}" in
  on) on ;;
  off) off ;;
  status) [ -f "$STATE" ] && echo on || echo off ;;
  *) if [ -f "$STATE" ]; then off; else on; fi ;;
esac
