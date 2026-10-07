#!/bin/bash
PROFILE=$(powerprofilesctl get 2>/dev/null || echo balanced)
CAP=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || cat /sys/class/power_supply/BAT1/capacity 2>/dev/null || echo 0)
STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || cat /sys/class/power_supply/BAT1/status 2>/dev/null || echo Unknown)

# Battery time estimate calculation
get_bat_est() {
  local b="/sys/class/power_supply/BAT0"
  [ ! -d "$b" ] && b=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)
  [ -z "$b" ] && return

  local st=$(cat "$b/status" 2>/dev/null)
  local now=$(cat "$b/charge_now" 2>/dev/null || cat "$b/energy_now" 2>/dev/null)
  local full=$(cat "$b/charge_full" 2>/dev/null || cat "$b/energy_full" 2>/dev/null)
  local rate=$(cat "$b/current_now" 2>/dev/null || cat "$b/power_now" 2>/dev/null)

  if [ "$st" = "Discharging" ] && [ -n "$now" ] && [ -n "$rate" ] && [ "$rate" -gt 0 ]; then
    local mins=$(( now * 60 / rate ))
    local h=$(( mins / 60 ))
    local m=$(( mins % 60 ))
    if [ $h -gt 0 ]; then
      echo "(${h}h ${m}m)"
    else
      echo "(${m}m)"
    fi
  elif [ "$st" = "Charging" ] && [ -n "$full" ] && [ -n "$now" ] && [ -n "$rate" ] && [ "$rate" -gt 0 ]; then
    local rem=$(( full - now ))
    local mins=$(( rem * 60 / rate ))
    local h=$(( mins / 60 ))
    local m=$(( mins % 60 ))
    if [ $h -gt 0 ]; then
      echo "(${h}h ${m}m to full)"
    else
      echo "(${m}m to full)"
    fi
  else
    # Fallback to upower if available
    if command -v upower >/dev/null 2>&1; then
      local up_bat=$(upower -e 2>/dev/null | grep -i bat | head -1)
      if [ -n "$up_bat" ]; then
        local t_empty=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/time to empty/{print $2}' | xargs)
        local t_full=$(upower -i "$up_bat" 2>/dev/null | awk -F: '/time to full/{print $2}' | xargs)
        if [ -n "$t_empty" ]; then echo "($t_empty)"; return; fi
        if [ -n "$t_full" ]; then echo "($t_full to full)"; return; fi
      fi
    fi
  fi
}

EST=$(get_bat_est)

case "$PROFILE" in
  power-saver)
    ICON="🛡️"
    ;;
  performance)
    ICON="🗡️"
    ;;
  balanced|*)
    ICON="🔋"
    ;;
esac

if [ "$STATUS" = "Charging" ] || [ "$STATUS" = "Full" ]; then
  if [ -n "$EST" ]; then
    echo "⚡ $CAP% $EST"
  else
    echo "⚡ $CAP%"
  fi
else
  if [ -n "$EST" ]; then
    echo "$ICON $CAP% $EST"
  else
    echo "$ICON $CAP%"
  fi
fi
