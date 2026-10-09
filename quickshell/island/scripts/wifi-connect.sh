#!/usr/bin/env bash
# wifi-connect.sh <ssid> [password]: saved network -> bring it up; otherwise create it (password if given)
ssid=$1; pw=$2
saved=false
nmcli -t -f NAME connection show | grep -Fxq -- "$ssid" && saved=true

if $saved; then
  out=$(nmcli connection up id "$ssid" 2>&1); rc=$?
elif [ -n "$pw" ]; then
  out=$(nmcli device wifi connect "$ssid" password "$pw" 2>&1); rc=$?
else
  out=$(nmcli device wifi connect "$ssid" 2>&1); rc=$?
fi

# Settings > Notifications > "only tell me about errors": 1 = skip the success notification
quiet=$(head -n1 "$HOME/.local/state/island/conn-errors-only" 2>/dev/null)

if [ $rc -eq 0 ]; then
  [ "$quiet" = 1 ] || notify-send -a "Wi-Fi" "Connected" "$ssid" -i network-wireless
else
  # a profile we just created with a wrong password would block the next try
  $saved || nmcli connection delete id "$ssid" >/dev/null 2>&1
  notify-send -a "Wi-Fi" "Couldn't connect to $ssid" "$(printf '%s' "$out" | head -1)" -i dialog-warning
fi
