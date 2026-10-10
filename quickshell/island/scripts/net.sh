#!/usr/bin/env bash
# one JSON line every $1 seconds (default 4): wifi / ethernet / bluetooth state
# Lean on purpose (this runs all day): ~3-5 child processes per tick instead of ~16. The text handling is done with bash itself
# (no grep / head / cut / sed pipelines), the SSID list is only read while a Wi-Fi network is connected, and the wait between
# ticks is a timed `read` on a pipe nobody writes to, so not even a `sleep` process is started.
iv=${1:-4}
# Pace: $1 seconds normally, 2.5x / 5x when Settings > Performance & memory > "Background refresh" is Relaxed / Slow
# (flag file ~/.local/state/island/bg-refresh). The wait is a timed read on a pipe in $XDG_RUNTIME_DIR that wifi-connect.sh,
# bt-set.sh and the island poke after a change, so the bar never lags behind an action you just did.
st="$HOME/.local/state/island"
wake="${XDG_RUNTIME_DIR:-/tmp}/halcyon-net.wake"
[ -e "$wake" ] && [ ! -p "$wake" ] && rm -f "$wake"
[ -p "$wake" ] || mkfifo -m 600 "$wake" 2>/dev/null
if [ -p "$wake" ]; then exec {nap}<>"$wake"; else exec {nap}<> <(:); fi
wait_tick() {
  local m n=$iv
  { read -r m < "$st/bg-refresh"; } 2>/dev/null || m=normal
  case "$m" in relaxed) n=$(( iv * 5 / 2 )) ;; slow) n=$(( iv * 5 )) ;; esac
  if read -r -t "$n" -u "$nap" _; then read -r -t 1 -u "$nap" _; fi   # poked: let the action finish, then look
}
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
nl=$'\n'

while true; do
  wifi=off
  sig=0
  [ "$(nmcli -t radio wifi 2>/dev/null)" = "enabled" ] && wifi=on

  # one call for both: is a Wi-Fi network up, is the cable plugged in
  devs=$(nmcli -t -f TYPE,STATE dev 2>/dev/null)
  eth=false; ssid=""
  case "$nl$devs" in *"${nl}ethernet:connected"*) eth=true ;; esac
  case "$nl$devs" in
    *"${nl}wifi:connected"*)
      while IFS= read -r l; do
        case "$l" in yes:*) l=${l#yes:}; sig=${l%%:*}; ssid=$(esc "${l#*:}"); break ;; esac
      done < <(nmcli -t -f active,signal,ssid dev wifi 2>/dev/null)
      case "$sig" in ''|*[!0-9]*) sig=0 ;; esac
      ;;
  esac

  bt=off; btdev=""
  case "$(bluetoothctl show 2>/dev/null)" in
    *"Powered: yes"*)
      bt=on
      IFS= read -r l < <(bluetoothctl devices Connected 2>/dev/null)
      if [ -n "$l" ]; then read -r _ _ l <<<"$l"; btdev=$(esc "$l"); fi
      ;;
  esac

  printf '{"wifi":"%s","ssid":"%s","eth":%s,"bt":"%s","btdev":"%s","signal":%s}\n' "$wifi" "$ssid" "$eth" "$bt" "$btdev" "$sig"
  wait_tick
done
