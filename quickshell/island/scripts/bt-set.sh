#!/usr/bin/env bash
# bt-set.sh connect|disconnect <mac> [name]
act=$1; mac=$2; name=${3:-$2}
# Settings > Notifications > "only tell me about errors": 1 = skip the success notifications
quiet=$(head -n1 "$HOME/.local/state/island/conn-errors-only" 2>/dev/null)
if out=$(bluetoothctl "$act" "$mac" 2>&1) && ! printf '%s' "$out" | grep -qi "fail"; then
  [ "$quiet" = 1 ] && exit 0
  [ "$act" = connect ] && notify-send -a "Bluetooth" "Connected" "$name" -i bluetooth \
                       || notify-send -a "Bluetooth" "Disconnected" "$name" -i bluetooth
else
  notify-send -a "Bluetooth" "Couldn't $act $name" "$(printf '%s' "$out" | tail -1)" -i dialog-warning
fi
