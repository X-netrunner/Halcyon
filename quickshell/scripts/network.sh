#!/bin/bash
STATE=$(nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -E 'wifi:connected|ethernet:connected')
if [ -n "$STATE" ]; then
  ESSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2)
  if [ -n "$ESSID" ]; then
    echo "󰤨 $ESSID"
  else
    echo "󰈀 Connected"
  fi
else
  echo ""
fi
