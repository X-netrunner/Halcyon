#!/bin/bash
PROFILE=$(powerprofilesctl get 2>/dev/null || echo balanced)
CAP=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || cat /sys/class/power_supply/BAT1/capacity 2>/dev/null || echo 0)
STATUS=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || cat /sys/class/power_supply/BAT1/status 2>/dev/null || echo Unknown)

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
  echo "⚡ $CAP%"
else
  echo "$ICON $CAP%"
fi
