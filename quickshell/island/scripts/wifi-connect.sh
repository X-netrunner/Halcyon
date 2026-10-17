#!/usr/bin/env bash
# wifi-connect.sh <ssid> [password]: saved network -> bring it up; otherwise create it (password if given)
ssid=$1; pw=$2
# wake net.sh (the bar's Wi-Fi / Bluetooth label) so it shows the result now, not at its next slow tick
poke_net() { local f="${XDG_RUNTIME_DIR:-/tmp}/halcyon-net.wake"; [ -p "$f" ] && printf '\n' 1<>"$f"; }
trap poke_net EXIT
# (terse output used to escape ':' and '\' in names, so a saved "Cafe: Guest" was not recognised as saved - and if that connect then
# failed, the profile "we just created" was deleted: the user's own saved network and its password.)
# saved  = a Wi-Fi profile with exactly this name exists;  exists = a profile of any kind has this name (never deleted below)
saved=false; exists=false
while IFS= read -r line; do
  [ "${line%:*}" = "$ssid" ] || continue
  exists=true
  case "${line##*:}" in wifi|802-11-wireless) saved=true ;; esac
done < <(nmcli -t -e no -f NAME,TYPE connection show 2>/dev/null)

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
  # a profile we just created with a wrong password would block the next try (only one this run made: never one that was already there)
  $exists || nmcli connection delete id "$ssid" >/dev/null 2>&1
  notify-send -a "Wi-Fi" "Couldn't connect to $ssid" "$(printf '%s' "$out" | head -1)" -i dialog-warning
fi
