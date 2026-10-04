#!/usr/bin/env bash
# bt-set.sh connect|disconnect <mac> [name]
act=$1; mac=$2; name=${3:-$2}
if out=$(bluetoothctl "$act" "$mac" 2>&1) && ! printf '%s' "$out" | grep -qi "fail"; then
  [ "$act" = connect ] && notify-send -a "Bluetooth" "Connected" "$name" -i bluetooth \
                       || notify-send -a "Bluetooth" "Disconnected" "$name" -i bluetooth
else
  notify-send -a "Bluetooth" "Couldn't $act $name" "$(printf '%s' "$out" | tail -1)" -i dialog-warning
fi
