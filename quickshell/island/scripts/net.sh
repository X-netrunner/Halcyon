#!/usr/bin/env bash
# one JSON line every $1 seconds (default 4): wifi / ethernet / bluetooth state
iv=${1:-4}
esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }

while true; do
  wifi=off
  [ "$(nmcli -t radio wifi 2>/dev/null)" = "enabled" ] && wifi=on
  ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | head -1 | cut -d: -f2- | esc)
  eth=false
  nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -q '^ethernet:connected' && eth=true

  bt=off; btdev=""
  if bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
    bt=on
    btdev=$(bluetoothctl devices Connected 2>/dev/null | head -1 | cut -d' ' -f3- | esc)
  fi

  printf '{"wifi":"%s","ssid":"%s","eth":%s,"bt":"%s","btdev":"%s"}\n' "$wifi" "$ssid" "$eth" "$bt" "$btdev"
  sleep "$iv"
done
