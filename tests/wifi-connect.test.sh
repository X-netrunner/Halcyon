#!/usr/bin/env bash
# quickshell/island/scripts/wifi-connect.sh: bash tests/wifi-connect.test.sh
# A fake nmcli walks through NetworkManager's states; the script must report every step, say why a connection failed, never print
# or log the password, and never delete a profile it did not create.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/quickshell/island/scripts/wifi-connect.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp"
cat > "$tmp/bin/nmcli" <<'FAKE'
#!/usr/bin/env bash
cnt="$XDG_RUNTIME_DIR/cnt"; [ -f "$cnt" ] || echo 0 > "$cnt"
case "$*" in
  "-t radio wifi") echo enabled ;;
  "-t -f DEVICE,TYPE,STATE device") echo "wlan0:wifi:disconnected"; echo "lo:loopback:unmanaged" ;;
  *"device wifi list"*) echo "78:WPA2:6:130 Mbit/s:Cafe: Guest"; echo "40:WPA2:11:65 Mbit/s:Home" ;;
  *"connection show"*) case "$MODE" in saved|savedbad) echo "Home:802-11-wireless" ;; esac; echo "lo:loopback" ;;
  *"device wifi connect"*|*"connection up"*)
    sleep 1.6
    if [ "$MODE" = badpw ] || [ "$MODE" = savedbad ]; then echo "Error: Connection activation failed: Secrets were required, but not provided."; exit 4; fi
    if [ "$MODE" = nodhcp ]; then echo "Error: Connection activation failed: IP configuration could not be reserved (no available address, timeout, etc.)"; exit 4; fi
    echo "Device 'wlan0' successfully activated"; exit 0 ;;
  *"GENERAL.STATE,GENERAL.REASON device show"*)
    n=$(cat "$cnt"); echo $((n + 1)) > "$cnt"
    case $n in 0) echo "GENERAL.STATE:30 (disconnected)";; 1) echo "GENERAL.STATE:40 (prepare)";; 2) echo "GENERAL.STATE:50 (config)";; 3) echo "GENERAL.STATE:60 (need-auth)";; 4) echo "GENERAL.STATE:70 (ip-config)";; 5) echo "GENERAL.STATE:80 (ip-check)";; *) echo "GENERAL.STATE:100 (connected)";; esac ;;
  *"IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show"*) echo "IP4.ADDRESS[1]:192.168.1.23/24"; echo "IP4.GATEWAY:192.168.1.1"; echo "IP4.DNS[1]:192.168.1.1" ;;
  *"networking connectivity check"*) echo full ;;
  *"connection delete"*) echo "$*" >> "$XDG_RUNTIME_DIR/deleted" ;;
esac
FAKE
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/notify-send"
printf '#!/bin/sh\necho "64 bytes from x: icmp_seq=1 ttl=64 time=2.41 ms"\n' > "$tmp/bin/ping"
chmod +x "$tmp/bin/"*
bad=0; n=0
check() { n=$((n + 1)); if [ "$2" != "$3" ]; then bad=$((bad + 1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
run() { echo 0 > "$tmp/cnt"; rm -f "$tmp/deleted"; MODE=$1 bash "$script" "${@:2}"; }

out=$(run ok "Cafe: Guest" "hunter2-secret"); rc=$?
check "a good connection exits 0" "$rc" "0"
for step in "Using adapter wlan0" 'Found it: signal 78%, WPA2, channel 6' "Preparing the connection" "Authenticating" "Asking the router for an IP address" \
            "Got IP address 192.168.1.23/24" "Router (gateway) 192.168.1.1" "DNS server 192.168.1.1" "Internet is reachable" 'Connected to "Cafe: Guest"'; do
  check "step shown: $step" "$(has "$step" "$out")" yes
done
check "every line is level|seconds|text" "$(printf '%s\n' "$out" | grep -vcE '^[iowe]\|[0-9]+\.[0-9]\|.+')" "0"
check "the password is never printed" "$(has hunter2 "$out")" no
check "the password is never logged" "$(has hunter2 "$(cat "$tmp/halcyon-wifi-connect.log")")" no
check "the log keeps the same lines" "$(wc -l < "$tmp/halcyon-wifi-connect.log")" "$(printf '%s\n' "$out" | wc -l)"

out=$(run badpw --plain "Cafe: Guest" wrong); rc=$?
check "a wrong password exits non-zero" "$((rc != 0))" "1"
check "it says the password was wrong" "$(has "Wrong password" "$out")" yes
check "a profile this run made is removed again" "$([ -s "$tmp/deleted" ] && echo yes || echo no)" yes

out=$(run savedbad --plain Home); rc=$?
check "a saved network that fails keeps its profile" "$([ -s "$tmp/deleted" ] && echo yes || echo no)" no
out=$(run saved Home); check "a saved network connects with the stored password" "$(has "stored password" "$out")" yes

out=$(run nodhcp --plain "Cafe: Guest" pw)
check "a DHCP failure is named" "$(has "no IP address (DHCP failed)" "$out")" yes

echo "$((n - bad))/$n checks passed"
exit $((bad > 0))
