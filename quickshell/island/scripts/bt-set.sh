#!/usr/bin/env bash
# bt-set.sh connect|disconnect <mac> [name]
act=$1; mac=$2; name=${3:-$2}
# wake net.sh (the bar's Wi-Fi / Bluetooth label) so it shows the result now, not at its next slow tick
poke_net() { local f="${XDG_RUNTIME_DIR:-/tmp}/halcyon-net.wake"; [ -p "$f" ] && printf '\n' 1<>"$f"; }
trap poke_net EXIT
# Settings > Notifications > "only tell me about errors": 1 = skip the success notifications
quiet=$(head -n1 "$HOME/.local/state/island/conn-errors-only" 2>/dev/null)
if out=$(bluetoothctl "$act" "$mac" 2>&1) && ! printf '%s' "$out" | grep -qi "fail"; then
  [ "$quiet" = 1 ] && exit 0
  [ "$act" = connect ] && notify-send -a "Bluetooth" "Connected" "$name" -i bluetooth \
                       || notify-send -a "Bluetooth" "Disconnected" "$name" -i bluetooth
else
  notify-send -a "Bluetooth" "Couldn't $act $name" "$(printf '%s' "$out" | tail -1)" -i dialog-warning
fi
