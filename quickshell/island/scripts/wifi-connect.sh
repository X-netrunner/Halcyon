#!/usr/bin/env bash
# wifi-connect.sh <ssid> [password]: saved network -> bring it up; otherwise create it (password if given)
#
# Verbose: every step is printed as one line  "<level>|<seconds>|<text>"  while it happens, and the same lines are kept in
# $XDG_RUNTIME_DIR/halcyon-wifi-connect.log (the last run only). level: i = step, o = done / good, w = warning, e = error.
# The Utilities box (Panel.qml) reads the lines and shows them under the Wi-Fi list; run it in a terminal to watch it too:
#     bash wifi-connect.sh "My network"        (or:  bash wifi-connect.sh --plain "My network" for readable text)
# The password is never printed or logged.
plain=false
[ "$1" = "--plain" ] && { plain=true; shift; }
ssid=$1; pw=$2
logf="${XDG_RUNTIME_DIR:-/tmp}/halcyon-wifi-connect.log"
: > "$logf" 2>/dev/null
t0=${EPOCHREALTIME:-$(date +%s.%N)}
say() {   # say <level> <text>
  local now=${EPOCHREALTIME:-$(date +%s.%N)} el line
  el=$(awk -v a="$now" -v b="$t0" 'BEGIN { printf "%.1f", a - b }' 2>/dev/null || echo 0)
  if $plain; then line=$(printf '[%5ss] %s' "$el" "$2"); else line="$1|$el|$2"; fi
  printf '%s\n' "$line"
  printf '%s|%s|%s\n' "$1" "$el" "$2" >> "$logf" 2>/dev/null
}
# wake net.sh (the bar's Wi-Fi / Bluetooth label) so it shows the result now, not at its next slow tick
poke_net() { local f="${XDG_RUNTIME_DIR:-/tmp}/halcyon-net.wake"; [ -p "$f" ] && printf '\n' 1<>"$f"; }
trap poke_net EXIT

if [ -z "$ssid" ]; then say e "No network name given"; exit 2; fi
command -v nmcli >/dev/null 2>&1 || { say e "NetworkManager (nmcli) is not installed"; exit 127; }

# ---- 1. the radio and the adapter
if [ "$(nmcli -t radio wifi 2>/dev/null)" != "enabled" ]; then
  say i "Wi-Fi radio is off, switching it on"
  nmcli radio wifi on >/dev/null 2>&1
  sleep 1.5
fi
dev=""
while IFS=: read -r d ty st; do
  [ "$ty" = wifi ] && { dev=$d; break; }
done < <(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null)
if [ -z "$dev" ]; then say e "No Wi-Fi adapter found"; exit 3; fi
say i "Using adapter $dev"

# ---- 2. the access point: signal, security, channel, speed (the SSID is the last field, so a ':' inside it is harmless)
say i "Looking for \"$ssid\""
sig=""; sec=""; chan=""; rate=""
while IFS= read -r l; do
  s=${l%%:*};       r=${l#*:}
  e=${r%%:*};       r=${r#*:}
  c=${r%%:*};       r=${r#*:}
  rt=${r%%:*};      name=${r#*:}
  if [ "$name" = "$ssid" ]; then
    case "$s" in ''|*[!0-9]*) ;; *) [ -z "$sig" ] || [ "$s" -gt "$sig" ] && { sig=$s; sec=$e; chan=$c; rate=$rt; } ;; esac
  fi
done < <(nmcli -t -e no -f SIGNAL,SECURITY,CHAN,RATE,SSID device wifi list --rescan no 2>/dev/null)
if [ -n "$sig" ]; then
  say o "Found it: signal $sig%, ${sec:-open}, channel $chan, $rate"
  [ "$sig" -lt 30 ] && say w "The signal is weak: the connection may be slow or fail"
else
  say w "Not in the last scan (hidden network, or out of range); trying anyway"
fi

# ---- 3. a saved profile, or a new one
# (terse output used to escape ':' and '\' in names, so a saved "Cafe: Guest" was not recognised as saved - and if that connect then
# failed, the profile "we just created" was deleted: the user's own saved network and its password.)
# saved  = a Wi-Fi profile with exactly this name exists;  exists = a profile of any kind has this name (never deleted below)
saved=false; exists=false
while IFS= read -r line; do
  [ "${line%:*}" = "$ssid" ] || continue
  exists=true
  case "${line##*:}" in wifi|802-11-wireless) saved=true ;; esac
done < <(nmcli -t -e no -f NAME,TYPE connection show 2>/dev/null)

outf=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/halcyon-wifi.XXXXXX") || outf=/dev/null
if $saved; then
  say i "Saved network: using the stored password"
  nmcli connection up id "$ssid" > "$outf" 2>&1 &
elif [ -n "$pw" ]; then
  say i "New network: creating a profile with the password you typed"
  nmcli device wifi connect "$ssid" password "$pw" > "$outf" 2>&1 &
else
  say i "Open network: creating a profile without a password"
  nmcli device wifi connect "$ssid" > "$outf" 2>&1 &
fi
pid=$!

# ---- 4. follow the adapter's state until nmcli is done (NetworkManager's own state numbers)
last=""; reason=""
while kill -0 "$pid" 2>/dev/null; do
  st=$(nmcli -t -f GENERAL.STATE,GENERAL.REASON device show "$dev" 2>/dev/null)
  code=""; why=""
  while IFS= read -r l; do
    case "$l" in
      GENERAL.STATE:*)  code=${l#GENERAL.STATE:}; code=${code%% *} ;;
      GENERAL.REASON:*) why=${l#GENERAL.REASON:}; why=${why#*(}; why=${why%)} ;;
    esac
  done <<< "$st"
  [ -n "$why" ] && [ "$why" != "No reason given" ] && [ "$why" != "none" ] && reason=$why
  if [ -n "$code" ] && [ "$code" != "$last" ]; then
    last=$code
    case "$code" in
      30) say i "Adapter idle" ;;
      40) say i "Preparing the connection" ;;
      50) say i "Joining \"$ssid\" (association)" ;;
      60) say i "Authenticating (security handshake)" ;;
      70) say i "Asking the router for an IP address (DHCP)" ;;
      80) say i "Checking the connection" ;;
      90) say i "Starting secondary connections" ;;
      100) say i "Link is up" ;;
    esac
  fi
  sleep 0.25
done
wait "$pid"; rc=$?
out=$(cat "$outf" 2>/dev/null); rm -f "$outf"

# Settings > Notifications > "only tell me about errors": 1 = skip the success notification
quiet=$(head -n1 "$HOME/.local/state/island/conn-errors-only" 2>/dev/null)

if [ $rc -eq 0 ]; then
  # ---- 5. what we got
  ip=""; gw=""; dns=""; spd=""
  while IFS= read -r l; do
    case "$l" in
      IP4.ADDRESS\[1\]:*) ip=${l#*:} ;;
      IP4.GATEWAY:*)      gw=${l#*:} ;;
      IP4.DNS\[1\]:*)     dns=${l#*:} ;;
    esac
  done < <(nmcli -t -e no -f IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show "$dev" 2>/dev/null)
  [ -n "$ip" ]  && say o "Got IP address $ip" || say w "Connected, but no IPv4 address yet (the router may still be answering)"
  [ -n "$gw" ]  && say i "Router (gateway) $gw"
  [ -n "$dns" ] && say i "DNS server $dns"
  if [ -n "$gw" ] && command -v ping >/dev/null 2>&1; then
    p=$(ping -c1 -W1 "$gw" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\) ms.*/\1/p' | head -n1)
    [ -n "$p" ] && say o "Router answers in $p ms" || say w "The router did not answer a ping (some routers ignore pings)"
  fi
  say i "Checking for internet access"
  case "$(timeout 6 nmcli -t networking connectivity check 2>/dev/null)" in
    full)    say o "Internet is reachable" ;;
    portal)  say w "A sign-in page is in the way (captive portal): open a browser to log in" ;;
    limited) say w "Connected, but there is no internet access" ;;
    *)       say i "Internet check gave no answer" ;;
  esac
  say o "Connected to \"$ssid\""
  [ "$quiet" = 1 ] || notify-send -a "Wi-Fi" "Connected" "$ssid" -i network-wireless
else
  first=$(printf '%s' "$out" | head -n1)
  # (the DHCP message itself says "... no available address, timeout, etc.", so it has to be asked before the plain timeout)
  case "$out$reason" in
    *DHCP*|*"IP configuration"*|*"ip-config"*) say e "Joined the network, but the router gave no IP address (DHCP failed)" ;;
    *[Ss]ecrets*|*[Ss]upplicant*|*"802-1X"*|*"4-way"*|*"password"*|*"no-secrets"*|*"Authentication"*)
      say e "Wrong password (the security handshake was refused)" ;;
    *"No network with SSID"*) say e "The network is not in range" ;;
    *"timeout"*|*"Timeout"*|*"timed out"*) say e "Timed out: the router did not answer" ;;
    *) say e "Could not connect${reason:+ ($reason)}" ;;
  esac
  [ -n "$first" ] && say i "nmcli said: $first"
  # a profile we just created with a wrong password would block the next try (only one this run made: never one that was already there)
  if ! $exists; then
    nmcli connection delete id "$ssid" >/dev/null 2>&1
    say i "The half-made profile was removed so you can try again"
  fi
  notify-send -a "Wi-Fi" "Couldn't connect to $ssid" "$first" -i dialog-warning
fi
exit $rc
