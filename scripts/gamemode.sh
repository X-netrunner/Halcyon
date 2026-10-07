#!/usr/bin/env bash
# Gaming mode: on | off | toggle | status.  Run by the island (Gaming chip / Settings / SUPER+F10).
#   on   performance power profile (Auto power paused), Hyprland animations / blur / shadows / gaps / rounding off,
#        allow tearing, CPU governor performance, GPU performance mode, Caffeine on, DND on, background helpers stopped.
#   off  power profile, CPU/GPU, Hyprland config restored; Caffeine and DND go back to what they were before (a Caffeine or
#        DND you had switched on yourself stays on).
# Edit ~/.config/Halcyon/gamemode.conf to choose what gets stopped:
#   KILL="cava baloo_file baloo_file_extractor tracker-miner-fs-3 tracker-extract-3 syncthing"   # processes killed by name (never restarted)
#   STOP_SERVICES=""                                                                            # user services stopped now, started again on `off`

STATE=/dev/shm/halcyon-gamemode
CONF="$HOME/.config/Halcyon/gamemode.conf"
KILL="cava baloo_file baloo_file_extractor tracker-miner-fs-3 tracker-extract-3 syncthing dropbox nextcloud"
STOP_SERVICES=""
[ -f "$CONF" ] && . "$CONF"

note() { command -v notify-send >/dev/null && ( timeout 3 notify-send -a Halcyon -i applications-games -t 3000 "Gaming mode" "$1" >/dev/null 2>&1 & ); }
hl() { timeout 4 hyprctl "$@" >/dev/null 2>&1; }
island() { timeout 4 quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island "$@" >/dev/null 2>&1; }
dnd_was_on() { grep -q '"dnd": *true' "$HOME/.local/state/island/settings.json" 2>/dev/null; }

on() {
  [ -f "$STATE" ] && return 0     # already on

  # Save state
  prof=$(powerprofilesctl get 2>/dev/null || echo balanced)
  auto=no; systemctl --user is-active --quiet power-manager.service && auto=yes
  caf=no; [ "$(bash "$HOME/.config/Halcyon/scripts/caffeine.sh" status 2>/dev/null)" = on ] && caf=yes
  dnd=no; dnd_was_on && dnd=yes

  { 
    echo "profile=$prof"
    echo "auto=$auto"
    echo "caf=$caf"
    echo "dnd=$dnd"
    echo "stopped=$(for s in $STOP_SERVICES; do systemctl --user is-active --quiet "$s" && printf '%s ' "$s"; done)"
  } > "$STATE"

  # 1. Power Manager & Power Profile -> Performance
  timeout 4 systemctl --user stop power-manager.service 2>/dev/null
  timeout 4 powerprofilesctl set performance 2>/dev/null

  # 2. CPU governor / EPP / turbo, GPU clocks, swappiness, Wi-Fi power save (root part: halcyon-tune, see install.sh)
  timeout 6 sudo -n /usr/local/bin/halcyon-tune game-on 2>/dev/null || tune_failed=1

  # 3. NVIDIA: prefer maximum performance
  command -v nvidia-settings >/dev/null 2>&1 && timeout 4 nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=1' >/dev/null 2>&1

  # 4. Feral GameMode daemon (per-game renice / ioprio / GPU hints) available while gaming mode is on
  systemctl --user start gamemoded.service >/dev/null 2>&1

  # 5. Hyprland: effects off. One call per group, so a option this Hyprland version does not know can only break its own call
  hl eval "hl.config({ animations = { enabled = false }, decoration = { blur = { enabled = false }, shadow = { enabled = false }, rounding = 0, dim_inactive = false }, general = { gaps_in = 0, gaps_out = 0 } })"
  hl eval "hl.config({ general = { allow_tearing = true } })"
  hl eval "hl.config({ misc = { vrr = 1 } })"
  hl eval "hl.config({ render = { direct_scanout = true } })"

  # 6. Caffeine (no sleep / dim) and Do not disturb (no popups); `off` puts both back as they were
  [ "$caf" = yes ] || bash "$HOME/.config/Halcyon/scripts/caffeine.sh" on 2>/dev/null || true
  island dndset true

  # 7. Stop background services & kill process list
  for s in $STOP_SERVICES; do systemctl --user stop "$s" 2>/dev/null; done
  for p in $KILL; do pkill -x "$p" 2>/dev/null; done

  [ -n "$tune_failed" ] && note "On (visuals only): run install.sh again so CPU/GPU boost works without a password" || note "On: CPU/GPU at full speed, turbo on, tearing & VRR allowed, Wi-Fi power save off, helpers paused"
}

off() {
  [ -f "$STATE" ] || return 0
  # read the saved values; never `source` this file: /dev/shm is writable by every local user
  profile=balanced; auto=no; caf=no; dnd=no; stopped=""
  while IFS='=' read -r k v; do
    case "$k" in
      profile) case "$v" in power-saver|balanced|performance) profile=$v ;; esac ;;
      auto) [ "$v" = yes ] && auto=yes ;;
      caf) [ "$v" = yes ] && caf=yes ;;
      dnd) [ "$v" = yes ] && dnd=yes ;;
      stopped) stopped=$v ;;
    esac
  done < "$STATE"
  rm -f "$STATE"

  # Restore Power Profile & Manager
  timeout 4 powerprofilesctl set "${profile:-balanced}" 2>/dev/null
  [ "$auto" = yes ] && timeout 4 systemctl --user start power-manager.service 2>/dev/null

  # Restore CPU / GPU / Wi-Fi settings
  timeout 6 sudo -n /usr/local/bin/halcyon-tune game-off 2>/dev/null

  # Caffeine and DND: only switch off what Gaming mode switched on
  [ "$caf" = yes ] || bash "$HOME/.config/Halcyon/scripts/caffeine.sh" off 2>/dev/null || true
  [ "$dnd" = yes ] || island dndset false

  # Restore background services
  for s in $stopped; do systemctl --user start "$s" 2>/dev/null; done

  # Reload Hyprland config
  hl reload

  note "Off: System restored to normal mode"
}

case "${1:-toggle}" in
  on) on ;;
  off) off ;;
  status) [ -f "$STATE" ] && echo on || echo off ;;
  *) if [ -f "$STATE" ]; then off; else on; fi ;;
esac
