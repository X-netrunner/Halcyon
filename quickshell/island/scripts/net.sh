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
# Adaptive (Settings > Performance > Update speed): slow down while the machine is busy or running on a nearly empty battery,
# stay live on the mains. Sets m to normal | relaxed | slow. Bash builtins only (no process), same rules as the Rust feed in src/hx.
cores=$(nproc 2>/dev/null || echo 1)
adaptive_pace() {
  local l1 cap st b
  m=normal
  read -r l1 _ < /proc/loadavg 2>/dev/null; l1=${l1/./}; l1=$((10#${l1:-0}))       # hundredths
  [ "$l1" -ge $(( cores * 90 )) ] && { m=slow; return; }
  for b in /sys/class/power_supply/BAT*; do
    [ -r "$b/status" ] || continue
    read -r st < "$b/status"; read -r cap < "$b/capacity"
    if [ "$st" = Discharging ]; then case "$cap" in ''|*[!0-9]*) m=relaxed ;; *) [ "$cap" -le 20 ] && m=slow || m=relaxed ;; esac; fi
    return
  done
}
# --- Adaptive, the part that learns (same file and rules as Learner in src/hx/src/sysfeeds.rs, which does this for the Rust feed):
# how often does the Wi-Fi / Bluetooth picture REALLY change for this user (signal strength not counted)? Rarely = slower looks, up to
# 4x and never slower than one look a minute; often = live. Needs 3 days of use; live again for 5 minutes after a change. Island actions
# poke the wake pipe, so they never wait. File ~/.local/state/island/adaptive-net.tsv: "d <day>" a day it ran, "c <epoch>" a change.
lfile="$st/adaptive-net.tsv"
ldays=(); lchanges=(); lkey=""; lhave=0; lf=10
learn_load() {
  local now oldest k v; printf -v now '%(%s)T' -1; oldest=$(( now - 14 * 86400 ))
  ldays=(); lchanges=()
  if [ -r "$lfile" ]; then
    while read -r k v; do
      case "$v" in ''|*[!0-9]*) continue ;; esac
      case "$k" in
        d) [ $(( v * 86400 + 86400 )) -gt "$oldest" ] && ldays+=("$v") ;;
        c) [ "$v" -gt "$oldest" ] && lchanges+=("$v") ;;
      esac
    done < "$lfile"
    { for v in "${ldays[@]}"; do echo "d $v"; done; for v in "${lchanges[@]}"; do echo "c $v"; done; } > "$lfile.tmp" 2>/dev/null && mv "$lfile.tmp" "$lfile"
  fi
}
learn_seen() {   # one sample line: note the day, and a change of anything except the signal strength
  local line=$1 key now day d have=0
  key=${line%,\"signal\":*}
  printf -v now '%(%s)T' -1; day=$(( now / 86400 ))
  if [ ! -e "$lfile" ] && { [ "${#ldays[@]}" -gt 0 ] || [ "${#lchanges[@]}" -gt 0 ]; }; then ldays=(); lchanges=(); fi   # deleted = start again
  for d in "${ldays[@]}"; do [ "$d" = "$day" ] && have=1; done
  [ "$have" = 1 ] || { ldays+=("$day"); printf 'd %s\n' "$day" >> "$lfile" 2>/dev/null; }
  if [ "$lhave" = 1 ] && [ "$key" != "$lkey" ]; then
    lchanges+=("$now"); printf 'c %s\n' "$now" >> "$lfile" 2>/dev/null
    [ "${#lchanges[@]}" -gt 2000 ] && lchanges=("${lchanges[@]:1}")
  fi
  lkey=$key; lhave=1
}
learn_factor() {   # sets lf = 10 / 20 / 30 / 40 (tenths: 1x .. 4x)
  local now oldest d c n=0 days=0 last=0 rate10
  lf=10
  printf -v now '%(%s)T' -1; oldest=$(( now - 14 * 86400 ))
  for d in "${ldays[@]}"; do [ $(( d * 86400 + 86400 )) -gt "$oldest" ] && days=$(( days + 1 )); done
  [ "$days" -ge 3 ] || return 0
  for c in "${lchanges[@]}"; do [ "$c" -gt "$oldest" ] && { n=$(( n + 1 )); last=$c; }; done
  [ "$last" -gt 0 ] && [ $(( now - last )) -lt 300 ] && return 0
  rate10=$(( n * 10 / days ))
  if [ "$rate10" -lt 10 ]; then lf=40; elif [ "$rate10" -lt 40 ]; then lf=30; elif [ "$rate10" -lt 120 ]; then lf=20; fi
}
wait_tick() {
  local m was n=$iv base
  { read -r m < "$st/bg-refresh"; } 2>/dev/null || m=normal
  was=$m
  [ "$m" = auto ] && adaptive_pace
  case "$m" in relaxed) n=$(( iv * 5 / 2 )) ;; slow) n=$(( iv * 5 )) ;; esac
  if [ "$was" = auto ]; then
    learn_factor; base=$n; n=$(( n * lf / 10 ))
    [ "$n" -gt 60 ] && { [ "$base" -gt 60 ] && n=$base || n=60; }
  fi
  if read -r -t "$n" -u "$nap" _; then read -r -t 1 -u "$nap" _; fi   # poked: let the action finish, then look
}
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
# nmcli -t writes ':' and '\' inside a value as "\:" and "\\" (a network called "Cafe: Guest" arrived as "Cafe\: Guest" and was shown that way)
unesc() { local s=${1//\\\\/$'\001'}; s=${s//\\:/:}; printf '%s' "${s//$'\001'/\\}"; }
nl=$'\n'

learn_load
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
        case "$l" in yes:*) l=${l#yes:}; sig=${l%%:*}; ssid=$(esc "$(unesc "${l#*:}")"); break ;; esac
      done < <(nmcli -t -f active,signal,ssid dev wifi list --rescan no 2>/dev/null)
      case "$sig" in ''|*[!0-9]*) sig=0 ;; esac
      ;;
  esac

  # btdev = the first connected device (its name), btn = how many are connected (the dots in the combined status icon)
  bt=off; btdev=""; btn=0
  case "$(bluetoothctl show 2>/dev/null)" in
    *"Powered: yes"*)
      bt=on
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        btn=$((btn + 1))
        if [ -z "$btdev" ]; then read -r _ _ l <<<"$l"; btdev=$(esc "$l"); fi
      done < <(bluetoothctl devices Connected 2>/dev/null)
      ;;
  esac

  printf -v line '{"wifi":"%s","ssid":"%s","eth":%s,"bt":"%s","btdev":"%s","btn":%s,"signal":%s}' "$wifi" "$ssid" "$eth" "$bt" "$btdev" "$btn" "$sig"
  printf '%s\n' "$line"
  learn_seen "$line"
  wait_tick
done
