#!/usr/bin/env bash
# one JSON line every $1 seconds (default 2): cpu/mem/temp/net/battery
# + sysmode (/etc/sysmode.mode, written by the `sysmode` CLI)
# + auto / pmode / pprofile (power-manager daemon: running? + its state file, see src/power-manager)
iv=${1:-2}

read -r _ u n s i io irq sirq st _ < /proc/stat
pt=$((u+n+s+i+io+irq+sirq+st)); pi=$((i+io))
read -r prx ptx < <(sed 's/:/ /' /proc/net/dev | awk 'NR>2 && $1!="lo" {rx+=$2; tx+=$10} END{print rx+0, tx+0}')

pm_state="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/power-manager.state"

bat=""
for b in /sys/class/power_supply/BAT*; do [ -d "$b" ] && bat=$b && break; done

while true; do
  sleep "$iv"

  read -r _ u n s i io irq sirq st _ < /proc/stat
  t=$((u+n+s+i+io+irq+sirq+st)); idl=$((i+io))
  dt=$((t-pt)); di=$((idl-pi)); cpu=0
  [ "$dt" -gt 0 ] && cpu=$(( 100*(dt-di)/dt ))
  pt=$t; pi=$idl

  read -r mt ma < <(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t, a}' /proc/meminfo)
  mem=$(( (mt-ma)*100/mt ))
  memgb=$(awk -v u=$((mt-ma)) 'BEGIN{printf "%.1f", u/1048576}')

  temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
  temp=$(( ${temp:-0}/1000 ))

  read -r rx tx < <(sed 's/:/ /' /proc/net/dev | awk 'NR>2 && $1!="lo" {rx+=$2; tx+=$10} END{print rx+0, tx+0}')
  down=$(( (rx-prx)/iv )); up=$(( (tx-ptx)/iv ))
  [ "$down" -lt 0 ] && down=0; [ "$up" -lt 0 ] && up=0
  prx=$rx; ptx=$tx

  hasbat=false; cap=0; chg=false
  if [ -n "$bat" ]; then
    hasbat=true
    cap=$(cat "$bat/capacity" 2>/dev/null || echo 0)
    [ "$(cat "$bat/status" 2>/dev/null)" = "Charging" ] && chg=true
  fi

  ac=false
  for p in /sys/class/power_supply/*; do
    [ "$(cat "$p/type" 2>/dev/null)" = "Mains" ] && [ "$(cat "$p/online" 2>/dev/null)" = "1" ] && ac=true
  done

  # sysmode: secure | stealth | cyber | lockdown ("" = never set). `hacking` is an alias of stealth.
  sm=""
  { read -r sm < /etc/sysmode.mode; } 2>/dev/null || sm=""
  sm=${sm//[^a-z-]/}
  [ "$sm" = "hacking" ] && sm="stealth"

  # Auto power = the power-manager daemon is running (any build; pgrep, not the state file, so an
  # old binary or a slow poll can never make Auto look "off"). The state file only adds the reason.
  auto=false; pmode=""; pprof=""
  if pgrep -x power-manager >/dev/null 2>&1; then
    auto=true
    now=$(printf '%(%s)T' -1)
    if { read -r pmode pprof pts < "$pm_state"; } 2>/dev/null && [ -n "$pts" ] && [ $((now - pts)) -lt 90 ]; then
      pmode=${pmode//[^a-z-]/}; pprof=${pprof//[^a-z-]/}
      [ "$pprof" = "-" ] && pprof=""
    else
      pmode=""; pprof=""
    fi
  fi

  printf '{"cpu":%d,"mem":%d,"memGb":"%s","temp":%d,"down":%d,"up":%d,"bat":%d,"charging":%s,"ac":%s,"hasBat":%s,"sysmode":"%s","auto":%s,"pmode":"%s","pprofile":"%s"}\n' \
    "$cpu" "$mem" "$memgb" "$temp" "$down" "$up" "$cap" "$chg" "$ac" "$hasbat" "$sm" "$auto" "$pmode" "$pprof"
done
