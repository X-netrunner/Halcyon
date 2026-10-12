#!/usr/bin/env bash
# Halcyon: the lab Wi-Fi hotspot.
#
#   hotspot.sh on | off | status
#
# Used by the fish functions hotspot-on / hotspot-off (config/fish/functions) and by the quick console, which runs
# bash and so cannot see fish functions. It can also be run by hand from any shell. Invoked under the name
# hotspot-on / hotspot-off (a symlink) it does that action.
#
# SSID / password: HOTSPOT_SSID / HOTSPOT_PASS (default BlackHatLab / password123; the password needs 8+ characters).
# The connection is called "Halcyon-Hotspot", so it never touches the decoy hotspot that `sysmode stealth --hotspot`
# starts (that one is NetworkManager's default "Hotspot").
set -u

SSID="${HOTSPOT_SSID:-BlackHatLab}"
PASS="${HOTSPOT_PASS:-password123}"
CON="Halcyon-Hotspot"

# colours only on a real terminal (the quick console shows plain text)
if [ -t 1 ]; then Y=$'\e[1;33m'; C=$'\e[1;36m'; G=$'\e[1;32m'; R=$'\e[1;31m'; Z=$'\e[0m'; else Y=; C=; G=; R=; Z=; fi
say()  { printf '%s[i]%s %s\n' "$C" "$Z" "$*"; }
good() { printf '%s[+]%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$Z" "$*"; }
bad()  { printf '%s[x]%s %s\n' "$R" "$Z" "$*" >&2; }

need_nmcli() { command -v nmcli >/dev/null 2>&1 || { bad "nmcli (NetworkManager) is not installed"; exit 1; }; }
wifi_dev()   { nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" { print $1; exit }'; }
is_on()      { nmcli -t -f NAME connection show --active 2>/dev/null | grep -qxF "$CON"; }

on() {
  need_nmcli
  local dev
  dev=$(wifi_dev)
  [ -n "$dev" ] || { bad "no Wi-Fi adapter found"; exit 1; }
  if [ "${#PASS}" -lt 8 ]; then bad "the hotspot password needs at least 8 characters (HOTSPOT_PASS)"; exit 1; fi
  if is_on; then good "the hotspot is already on: SSID $SSID"; return 0; fi

  if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "0" ]; then
    warn "IP forwarding is off (secure / lockdown mode): clients may not get internet through the hotspot."
    say  "Run: sudo sysmode relaxed to allow forwarding."
  fi

  # NetworkManager drops a normal Wi-Fi connection on the same adapter while the hotspot runs
  if nmcli device wifi hotspot ifname "$dev" con-name "$CON" ssid "$SSID" password "$PASS" >/dev/null 2>&1; then
    nmcli connection modify "$CON" connection.autoconnect no >/dev/null 2>&1   # never starts by itself at boot
    good "hotspot on ($dev): SSID $SSID, password $PASS"
  else
    bad "could not start the hotspot on $dev (Wi-Fi switched off? the adapter busy? try: nmcli radio wifi on)"
    exit 1
  fi
}

off() {
  need_nmcli
  if ! is_on; then say "no Halcyon hotspot is running"; return 0; fi
  if nmcli connection down "$CON" >/dev/null 2>&1; then
    good "hotspot off"
    local dev
    dev=$(wifi_dev)
    # put the adapter back on the normal Wi-Fi (a known network, when one is in range)
    [ -n "$dev" ] && timeout 20 nmcli device connect "$dev" >/dev/null 2>&1
    say "You can restore maximum protection with: sudo sysmode secure"
  else
    bad "could not stop the hotspot"
    exit 1
  fi
}

status() {
  need_nmcli
  if is_on; then good "hotspot is on: SSID $SSID"; else say "hotspot is off"; fi
}

action="${1:-}"
if [ -z "$action" ]; then
  case "$(basename "$0")" in hotspot-on) action=on ;; hotspot-off) action=off ;; *) action=status ;; esac
fi
case "$action" in
  on|start|up)      on ;;
  off|stop|down)    off ;;
  status)           status ;;
  *) echo "usage: hotspot.sh on | off | status" >&2; exit 2 ;;
esac
