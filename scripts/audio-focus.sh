#!/usr/bin/env bash
# audio-focus.sh : one thing plays at a time, and what you were listening to comes back by itself.
#   audio-focus.sh run       the watcher (started at login by scripts/autostart-extras.sh; Settings > Startup & background)
#   audio-focus.sh stop      stop it
#   audio-focus.sh status    is it running
# Works with every player that shows up on the media bus (MPRIS): Spotify, a YouTube / Netflix tab in Firefox or Chromium, mpv, VLC ...
#   - Something starts playing  -> whatever else was playing is paused, and remembered as "paused by me".
#   - That something stops (paused, finished, tab closed) -> only the players THIS script paused start again.
#   - Settings > Startup & background lets you turn the bring-back off and choose how long to wait first.
#   - A player you paused yourself is never touched: pause Spotify, play a video, stop it: Spotify stays paused.
#   - Steady on purpose: whatever THIS script just paused or started is ignored for a few seconds (a player is slow to report
#     the change, and a browser flickers Playing / Paused while a video buffers or an ad loads). Without that, the music it
#     had just brought back looked like "something new started" and the video got paused too.
# Needs playerctl. Sound that is not on the media bus (some games, a plain system beep) cannot be seen, so it is left alone.
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
pidf="${XDG_RUNTIME_DIR:-/tmp}/halcyon-audio-focus.pid"
TICK=1          # seconds between looks
conf="$RICE/autostart.conf"   # AUDIO_RESUME=1 (0 = never bring it back) and AUDIO_DELAY=2 (seconds of silence before it does); read every look, so Settings applies at once

case "${1:-run}" in
  stop)   [ -r "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"; exit 0 ;;
  status) [ -r "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null && { echo running; exit 0; }; echo stopped; exit 1 ;;
  run) ;;
  *) echo "usage: audio-focus.sh run | stop | status" >&2; exit 2 ;;
esac

command -v playerctl >/dev/null 2>&1 || { echo "audio-focus: playerctl is not installed" >&2; exit 1; }
[ -r "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null && exit 0          # already running
echo $$ > "$pidf"
trap 'rm -f "$pidf"; exit 0' INT TERM EXIT

COOL=4000       # ms: after the script pauses / starts a player, that player's next status changes are its own echo, not you
declare -A prev=()          # last status we saw per player
declare -A mine=()          # players this script paused (the only ones it may resume)
declare -A cool=()          # player -> epoch ms until which its changes are ignored (we just touched it)
quiet=0
nowms() { printf '%s' "$(( ${EPOCHREALTIME/[.,]/} / 1000 ))"; }

while sleep "$TICK"; do
  AUDIO_RESUME=1; AUDIO_DELAY=2
  [ -r "$conf" ] && . "$conf" 2>/dev/null
  case "$AUDIO_DELAY" in ''|*[!0-9]*) AUDIO_DELAY=2 ;; esac
  SETTLE=$(( AUDIO_DELAY / TICK )); [ "$SETTLE" -ge 1 ] || SETTLE=1     # nothing playing for this many looks in a row (a song change / the next video is not a stop)
  t=$(nowms)
  declare -A now=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    now[$p]=$(playerctl -p "$p" status 2>/dev/null)
  done < <(playerctl -l 2>/dev/null)

  playing=(); started=(); browser=0
  for p in "${!now[@]}"; do
    if [ "${now[$p]}" = Playing ]; then
      playing+=("$p")
      case "$p" in firefox*|chrom*|brave*|vivaldi*|opera*|zen*|librewolf*|floorp*|waterfox*|epiphany*|google-chrome*|microsoft-edge*) browser=1 ;; esac
      # a start is only a start when it was not caused by us (cooldown)
      if [ "${prev[$p]:-}" != Playing ] && [ "${cool[$p]:-0}" -le "$t" ]; then started+=("$p"); fi
    fi
  done

  # something new started while another player was already going: pause the others, remember them.
  # Two at once is a tie, so nothing is touched (better two sounds for a moment than the wrong one silenced).
  if [ "${#started[@]}" -eq 1 ] && [ "${#playing[@]}" -gt 1 ]; then
    s="${started[0]}"
    for p in "${playing[@]}"; do
      [ "$p" = "$s" ] && continue
      if playerctl -p "$p" pause 2>/dev/null; then mine[$p]=1; now[$p]=Paused; cool[$p]=$(( t + COOL )); fi
    done
  fi
  # a player that is playing again is no longer "paused by me" (you started it yourself), unless that is our own echo
  for p in "${playing[@]}"; do
    [ "${now[$p]}" = Playing ] && [ "${cool[$p]:-0}" -le "$t" ] && unset 'mine[$p]'
  done
  # forget players that are gone (tab closed, app quit)
  for p in "${!mine[@]}"; do [ -n "${now[$p]+x}" ] || unset 'mine[$p]'; done

  # nothing playing any more: after a short settle, give back what we took.
  # A browser flickers Paused while a video buffers or an ad loads, so it gets two more looks before that counts as a stop.
  if [ "${#playing[@]}" -eq 0 ] && [ "${#mine[@]}" -gt 0 ]; then
    quiet=$((quiet + 1)); need=$SETTLE; [ "${lastbrowser:-0}" = 1 ] && need=$(( SETTLE + 2 ))
    if [ "$quiet" -ge "$need" ]; then
      if [ "$AUDIO_RESUME" = 1 ]; then
        for p in "${!mine[@]}"; do
          # the status is read again right before: only a player that is still paused, and was not started by someone else meanwhile
          [ "$(playerctl -p "$p" status 2>/dev/null)" = Paused ] && playerctl -p "$p" play 2>/dev/null && cool[$p]=$(( t + COOL ))
        done
      fi
      mine=(); quiet=0
    fi
  else
    quiet=0
  fi
  [ "${#playing[@]}" -gt 0 ] && lastbrowser=$browser

  prev=(); for p in "${!now[@]}"; do prev[$p]="${now[$p]}"; done
  unset now
done
