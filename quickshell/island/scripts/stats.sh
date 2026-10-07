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
for b in /sys/class/power_supply/BAT* /sys/class/power_supply/bat* /sys/class/power_supply/CMB* /sys/class/power_supply/*battery*; do
  [ -d "$b" ] && bat=$b && break
done
if [ -z "$bat" ] && command -v upower >/dev/null 2>&1; then
  if upower -e 2>/dev/null | grep -q -i bat; then
    hasbat_upower=true
  fi
fi

while true; do
  sleep "$iv"

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
  down=$(( (rx - prx) / iv )); up=$(( (tx - ptx) / iv ))
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

    fmt() { local m=$1; if [ "$m" -ge 60 ]; then printf '%dh %02dm' $((m/60)) $((m%60)); else printf '%dm' "$m"; fi; }

    if [ "$st" = "Discharging" ] && [ -n "$now" ] && [ "${rate_avg:-0}" -gt 0 ]; then
      batest="$(fmt $(( now * 60 / rate_avg )))"
    elif [ "$st" = "Charging" ] && [ -n "$full" ] && [ -n "$now" ] && [ "${rate_avg:-0}" -gt 0 ] && [ "$full" -gt "$now" ]; then
      batest="$(fmt $(( (full - now) * 60 / rate_avg ))) to full"
    fi

    if [ -z "$batest" ] && [ "$st" != "Full" ] && command -v upower >/dev/null 2>&1; then
      up_bat=$(upower -e 2>/dev/null | grep -i bat | head -1)
      if [ -n "$up_bat" ]; then
        t_empty=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/time to empty/{print $2}' | xargs)
        t_full=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/time to full/{print $2}' | xargs)
        [ -n "$t_empty" ] && batest="$t_empty"
        [ -n "$t_full" ] && batest="$t_full to full"
      fi
    fi
  elif [ "$hasbat_upower" = true ] && command -v upower >/dev/null 2>&1; then
    up_bat=$(upower -e 2>/dev/null | grep -i bat | head -1)
    if [ -n "$up_bat" ]; then
      hasbat=true
      cap_str=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/percentage/{print $2}' | tr -d ' %' | xargs)
      cap=${cap_str:-0}
      st=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/state/{print $2}' | xargs)
      [ "$st" = "charging" ] && chg=true
      t_empty=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/time to empty/{print $2}' | xargs)
      t_full=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/time to full/{print $2}' | xargs)
      if [ -n "$t_empty" ]; then batest="$t_empty"; fi
      if [ -n "$t_full" ]; then batest="$t_full to full"; fi
    fi
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

  # sysmode: secure | stealth | cyber | lockdown ("" = never set). `hacking` is an alias of stealth.
  sm=""
  { read -r sm < /etc/sysmode.mode; } 2>/dev/null || sm=""
  sm=${sm//[^a-z-]/}
  [ "$sm" = "hacking" ] && sm="stealth"

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
