#!/bin/bash
CON=$(bluetoothctl info 2>/dev/null | grep 'Connected: yes')
if [ -n "$CON" ]; then
  DEV=$(bluetoothctl info 2>/dev/null | grep 'Name:' | cut -d: -f2 | xargs)
  if [ -n "$DEV" ]; then
    echo "󰂯 $DEV"
  else
    echo "󰂯 Connected"
  fi
else
  echo ""
fi
