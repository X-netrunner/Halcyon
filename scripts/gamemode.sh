#!/usr/bin/env bash
# Gaming mode: on | off | toggle | status.  Run by the island (Gaming chip / Settings / SUPER+F10).
#   on   performance power profile (Auto power paused), Hyprland animations / blur / shadows / gaps / rounding off,
#        allow tearing, CPU governor performance, GPU performance mode, Caffeine on, DND on, background helpers stopped.
#   off  power profile, CPU/GPU, Hyprland config restored; Caffeine and DND go back to what they were before (a Caffeine or
#        DND you had switched on yourself stays on).
# Edit ~/.config/Halcyon/gamemode.conf to choose what gets stopped:
#   KILL="cava baloo_file baloo_file_extractor tracker-miner-fs-3 tracker-extract-3 syncthing dropbox nextcloud"   # processes killed by name (never restarted; this is the default)
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
  # /dev/shm is writable by every local user: a symlink or a file owned by someone else is not our state, so refuse it
  if [ -L "$STATE" ] || { [ -e "$STATE" ] && [ ! -O "$STATE" ]; }; then
    note "Not started: $STATE is not yours (remove it as root)"; return 1
  fi
  [ -f "$STATE" ] && return 0     # already on

  # Save state
  prof=$(powerprofilesctl get 2>/dev/null || echo balanced)
  auto=no; systemctl --user is-active --quiet power-manager.service && auto=yes
  caf=no; [ "$(bash "$HOME/.config/Halcyon/scripts/caffeine.sh" status 2>/dev/null)" = on ] && caf=yes
  dnd=no; dnd_was_on && dnd=yes
  gmd=no; systemctl --user is-active --quiet gamemoded.service && gmd=yes

  nvpm=""
  if command -v nvidia-settings >/dev/null 2>&1; then
    nvpm=$(timeout 4 nvidia-settings -t -q '[gpu:0]/GPUPowerMizerMode' 2>/dev/null | head -n1)
    case "$nvpm" in ''|*[!0-9]*) nvpm="" ;; esac     # not readable (no X server / no NVIDIA GPU): leave it alone, now and on `off`
  fi

  (umask 077; {
    echo "profile=$prof"
    echo "auto=$auto"
    echo "caf=$caf"
    echo "dnd=$dnd"
    echo "stopped=$(for s in $STOP_SERVICES; do systemctl --user is-active --quiet "$s" && printf '%s ' "$s"; done)"
    echo "nvpm=$nvpm"
    echo "gmd=$gmd"
  } > "$STATE")

  # 1. Power Manager & Power Profile -> Performance
  timeout 4 systemctl --user stop power-manager.service 2>/dev/null
  timeout 4 powerprofilesctl set performance 2>/dev/null

  # 2. CPU governor / EPP / turbo, GPU clocks, swappiness, Wi-Fi power save (root part: halcyon-tune, see install.sh)
  timeout 6 sudo -n /usr/local/bin/halcyon-tune game-on 2>/dev/null || tune_failed=1

  # 3. NVIDIA: prefer maximum performance
  [ -n "$nvpm" ] && timeout 4 nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=1' >/dev/null 2>&1

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
  profile=balanced; auto=no; caf=no; dnd=no; stopped=""; nvpm=""; gmd=yes
  while IFS='=' read -r k v; do
    case "$k" in
      profile) case "$v" in power-saver|balanced|performance) profile=$v ;; esac ;;
      auto) [ "$v" = yes ] && auto=yes ;;
      caf) [ "$v" = yes ] && caf=yes ;;
      dnd) [ "$v" = yes ] && dnd=yes ;;
      stopped) for u in $v; do [[ $u =~ ^[A-Za-z0-9@:._-]+$ ]] && stopped+="$u "; done ;;     # unit names only
      nvpm) case "$v" in [0-9]|[0-9][0-9]) nvpm=$v ;; esac ;;
      gmd) [ "$v" = no ] && gmd=no ;;
    esac
  done < "$STATE"
  rm -f "$STATE"

  # Hyprland first: the config files put animations / blur / gaps back. This used to come last, after the power manager had
  # been started again; that one could still see the game (gamemoded keeps a finished game as a client for a moment), take
  # its "before gaming" snapshot of the effects while they were still off, and later "restore" them to off.
  hl reload

  # Feral's gamemoded: stopped again if `on` started it, so no stale client makes anything think a game still runs
  [ "$gmd" = yes ] || systemctl --user stop gamemoded.service >/dev/null 2>&1

  # Restore Power Profile & Manager
  timeout 4 powerprofilesctl set "${profile:-balanced}" 2>/dev/null
  [ "$auto" = yes ] && timeout 4 systemctl --user start power-manager.service 2>/dev/null

  # Restore CPU / GPU / Wi-Fi settings
  timeout 6 sudo -n /usr/local/bin/halcyon-tune game-off 2>/dev/null
  [ -n "$nvpm" ] && timeout 4 nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=$nvpm" >/dev/null 2>&1   # it was set to max performance by `on`

  # Caffeine and DND: only switch off what Gaming mode switched on
  [ "$caf" = yes ] || bash "$HOME/.config/Halcyon/scripts/caffeine.sh" off 2>/dev/null || true
  [ "$dnd" = yes ] || island dndset false

  # Restore background services
  for s in $stopped; do systemctl --user start "$s" 2>/dev/null; done

  note "Off: System restored to normal mode"
}

case "${1:-toggle}" in
  on) on ;;
  off) off ;;
  status) [ -f "$STATE" ] && echo on || echo off ;;
  *) if [ -f "$STATE" ]; then off; else on; fi ;;
esac
