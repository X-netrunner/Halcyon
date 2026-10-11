#!/usr/bin/env bash
# one JSON line every $1 seconds (default 2): cpu/mem/temp/net/battery
# + sysmode (/etc/sysmode.mode, written by the `sysmode` CLI)
# + auto / pmode / pprofile (power-manager daemon: running? + its state file, see src/power-manager)
iv=${1:-2}
# Pace: $1 seconds normally. Settings > Performance & memory > "Background refresh" writes ~/.local/state/island/bg-refresh
# (normal | relaxed | slow = 1x / 2.5x / 5x). While the performance page (or the bar's CPU / RAM / TEMP row) can be on screen the
# island writes stats-fast=1 and the pace stays at $1. Missing flag files = the old behaviour (every $1 seconds).
# The wait is a timed read on a pipe in $XDG_RUNTIME_DIR (no `sleep` process); the island pokes the pipe when a flag changes,
# so a change shows within a second instead of at the end of a slow wait.
sdir="$HOME/.local/state/island"     # (not `st`: that name is the CPU steal counter below)
wake="${XDG_RUNTIME_DIR:-/tmp}/halcyon-stats.wake"
[ -e "$wake" ] && [ ! -p "$wake" ] && rm -f "$wake"
[ -p "$wake" ] || mkfifo -m 600 "$wake" 2>/dev/null
if [ -p "$wake" ]; then exec {nap}<>"$wake"; else exec {nap}<> <(:); fi
wait_tick() {
  local m f n=$iv
  { read -r m < "$sdir/bg-refresh"; } 2>/dev/null || m=normal
  { read -r f < "$sdir/stats-fast"; } 2>/dev/null || f=1
  if [ "$f" != 1 ]; then case "$m" in relaxed) n=$(( iv * 5 / 2 )) ;; slow) n=$(( iv * 5 )) ;; esac; fi
  # poked (a flag changed): give it a second so the first sample after the change is not a tiny window
  if read -r -t "$n" -u "$nap" _; then read -r -t 1 -u "$nap" _; fi
}
tprev=${EPOCHREALTIME/[.,]/}

read -r _ u n s i io irq sirq st _ < /proc/stat
pt=$((u+n+s+i+io+irq+sirq+st)); pi=$((i+io))
read -r prx ptx < <(sed 's/:/ /' /proc/net/dev | awk 'NR>2 && $1!="lo" {rx+=$2; tx+=$10} END{print rx+0, tx+0}')

pm_state="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/power-manager.state"

bat=""
for b in /sys/class/power_supply/BAT* /sys/class/power_supply/bat* /sys/class/power_supply/CMB* /sys/class/power_supply/*battery*; do
  [ -d "$b" ] && bat=$b && break
done
# upower: looked up once; read at most every 15 s with ONE call (it used to be up to five forks on every tick)
up_bat=""; up_t=0; up_cap=0; up_st=""; up_est=""
if command -v upower >/dev/null 2>&1; then up_bat=$(upower -e 2>/dev/null | grep -i -m1 bat); fi
upower_read() {
  local now; printf -v now '%(%s)T' -1
  [ -n "$up_bat" ] && [ $((now - up_t)) -ge 15 ] || return 0
  up_t=$now
  IFS='|' read -r up_cap up_st up_est < <(upower -i "$up_bat" 2>/dev/null | awk -F: '
    function trim(v) { gsub(/^ +| +$/, "", v); return v }
    /percentage/ { p = trim($2); gsub(/%/, "", p) }
    /state/ { s = trim($2) }
    /time to empty/ { e = trim($2) }
    /time to full/ { f = trim($2) " to full" }
    END { print (p + 0) "|" s "|" (f != "" ? f : e) }')
}
fmt() { local m=$1; if [ "$m" -ge 60 ]; then printf '%dh %02dm' $((m/60)) $((m%60)); else printf '%dm' "$m"; fi; }

while true; do
  wait_tick
  tnow=${EPOCHREALTIME/[.,]/}; ems=$(( (tnow - tprev) / 1000 )); [ "$ems" -lt 1 ] && ems=1; tprev=$tnow

  read -r _ u n s i io irq sirq st _ < /proc/stat
  t=$((u+n+s+i+io+irq+sirq+st)); idl=$((i+io))
  dt=$((t-pt)); di=$((idl-pi)); cpu=0
  [ "$dt" -gt 0 ] && cpu=$(( 100*(dt-di)/dt ))
  pt=$t; pi=$idl

  mt=0; ma=0
  while read -r k v _; do
    case "$k" in
      MemTotal:) mt=$v ;;
      MemAvailable:) ma=$v; break ;;
    esac
  done < /proc/meminfo
  mem=0; memgb="0.0"
  if [ "$mt" -gt 0 ]; then
    mem=$(( (mt - ma) * 100 / mt ))
    u=$(( mt - ma ))
    memgb="$(( u / 1048576 )).$(( (u * 10 / 1048576) % 10 ))"
  fi

  temp=0
  for t in /sys/class/hwmon/hwmon*/temp1_input /sys/class/thermal/thermal_zone*/temp; do
    if [ -r "$t" ]; then
      read -r raw < "$t" 2>/dev/null || continue
      v=$(( raw / 1000 ))
      [ "$v" -gt "$temp" ] && [ "$v" -lt 120 ] && temp=$v
    fi
  done

  rx=0; tx=0
  while read -r line; do
    case "$line" in
      *lo:*|*Inter-*|*face*) continue ;;
      *:*)
        line="${line#*:}"
        set -- $line
        rx=$(( rx + $1 ))
        tx=$(( tx + $9 ))
        ;;
    esac
  done < /proc/net/dev
  down=$(( (rx - prx) * 1000 / ems )); up=$(( (tx - ptx) * 1000 / ems ))
  [ "$down" -lt 0 ] && down=0; [ "$up" -lt 0 ] && up=0
  prx=$rx; ptx=$tx

  hasbat=false; cap=0; chg=false; batest=""
  if [ -n "$bat" ]; then
    hasbat=true
    read -r cap < "$bat/capacity" 2>/dev/null || cap=0
    read -r st < "$bat/status" 2>/dev/null || st=""
    [ "$st" = "Charging" ] && chg=true

    now=""; full=""; rate=""
    if [ -r "$bat/charge_now" ] && [ -r "$bat/current_now" ]; then
      read -r now < "$bat/charge_now" 2>/dev/null
      read -r full < "$bat/charge_full" 2>/dev/null
      read -r rate < "$bat/current_now" 2>/dev/null
    elif [ -r "$bat/energy_now" ] && [ -r "$bat/power_now" ]; then
      read -r now < "$bat/energy_now" 2>/dev/null
      read -r full < "$bat/energy_full" 2>/dev/null
      read -r rate < "$bat/power_now" 2>/dev/null
    fi
    rate=${rate#-}
    case "$now$full$rate" in *[!0-9]*) now=""; full=""; rate="" ;; esac

    if [ "$st" != "$last_st" ]; then rate_avg=0; last_st=$st; fi
    if [ -n "$rate" ] && [ "$rate" -gt 0 ]; then
      if [ "${rate_avg:-0}" -le 0 ]; then rate_avg=$rate; else rate_avg=$(( (rate_avg * 7 + rate) / 8 )); fi
    fi

    if [ "$st" = "Discharging" ] && [ -n "$now" ] && [ "${rate_avg:-0}" -gt 0 ]; then
      batest="$(fmt $(( now * 60 / rate_avg )))"
    elif [ "$st" = "Charging" ] && [ -n "$full" ] && [ -n "$now" ] && [ "${rate_avg:-0}" -gt 0 ] && [ "$full" -gt "$now" ]; then
      batest="$(fmt $(( (full - now) * 60 / rate_avg ))) to full"
    fi

    if [ -z "$batest" ] && [ "$st" != "Full" ]; then upower_read; batest=$up_est; fi
  elif [ -n "$up_bat" ]; then
    upower_read
    hasbat=true; cap=${up_cap:-0}; [ "$up_st" = "charging" ] && chg=true; batest=$up_est
  fi

  ac=false
  for p in /sys/class/power_supply/*; do
    if [ -r "$p/type" ] && [ -r "$p/online" ]; then
      read -r ptype < "$p/type" 2>/dev/null
      if [ "$ptype" = "Mains" ]; then
        read -r ponline < "$p/online" 2>/dev/null
        [ "$ponline" = "1" ] && { ac=true; break; }
      fi
    fi
  done

  # sysmode: secure | stealth | relaxed | lockdown ("" = never set). `hacking` is an alias of stealth, `cyber` (old name) of relaxed.
  sm=""
  { read -r sm < /etc/sysmode.mode; } 2>/dev/null || sm=""
  sm=${sm//[^a-z-]/}
  [ "$sm" = "hacking" ] && sm="stealth"
  [ "$sm" = "cyber" ] && sm="relaxed"      # a file written before the rename

  # Auto power = the power-manager daemon is running
  auto=false; pmode=""; pprof=""
  if [ -r "$pm_state" ]; then
    now=$(printf '%(%s)T' -1)
    if read -r pmode pprof pts < "$pm_state" 2>/dev/null && [ -n "$pts" ] && [ $((now - pts)) -lt 90 ]; then
      auto=true
      pmode=${pmode//[^a-z-]/}; pprof=${pprof//[^a-z-]/}
      [ "$pprof" = "-" ] && pprof=""
    fi
  fi

  printf '{"cpu":%d,"mem":%d,"memGb":"%s","temp":%d,"down":%d,"up":%d,"bat":%d,"batEst":"%s","charging":%s,"ac":%s,"hasBat":%s,"sysmode":"%s","auto":%s,"pmode":"%s","pprofile":"%s"}\n' \
    "$cpu" "$mem" "$memgb" "$temp" "$down" "$up" "$cap" "$batest" "$chg" "$ac" "$hasbat" "$sm" "$auto" "$pmode" "$pprof"
done
