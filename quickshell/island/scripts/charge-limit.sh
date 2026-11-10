#!/usr/bin/env bash
# Battery charge limit: keep the battery at 80 % (kinder to it when the laptop sits on the charger) or let it charge fully.
#
#   charge-limit.sh status   prints "none" (this laptop has no charge limit), or the limit now: 100 = full charge, 80 = limited
#   charge-limit.sh toggle   full <-> limited          charge-limit.sh on | off   limited | full
#
# The limit is HALCYON_CHARGE_LIMIT (default 80). It is one number in the kernel's
# /sys/class/power_supply/BAT*/charge_control_end_threshold (ASUS, Lenovo, Framework, Dell and others have it). Writing it needs
# permission: udev/90-halcyon-battery.rules (install.sh copies it) gives your user that. Some laptops forget the limit at boot.

hal="$(dirname "$(readlink -f "$0")")/../../../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  "$hal" charge-limit "$@"; rc=$?
  [ "$rc" -ne 2 ] && exit "$rc"
fi

LIMIT=${HALCYON_CHARGE_LIMIT:-80}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=80 ;; esac
[ "$LIMIT" -ge 40 ] && [ "$LIMIT" -le 99 ] || LIMIT=80
f=""
for b in /sys/class/power_supply/BAT*; do
  [ -e "$b/charge_control_end_threshold" ] && { f="$b/charge_control_end_threshold"; break; }
done
[ -n "$f" ] || { echo none; exit 0; }
read -r cur < "$f" 2>/dev/null
case "$cur" in ''|*[!0-9]*) echo none; exit 0 ;; esac
case "${1:-status}" in
  status) echo "$cur"; exit 0 ;;
  toggle) if [ "$cur" -lt 100 ]; then new=100; else new=$LIMIT; fi ;;
  on)  new=$LIMIT ;;
  off) new=100 ;;
  *) echo "usage: charge-limit.sh status | toggle | on | off" >&2; exit 2 ;;
esac
if printf '%s\n' "$new" > "$f" 2>/dev/null; then
  echo "$new"
else
  notify-send -a Halcyon -i battery "Charge limit" "Cannot change it: your user may not write $f. Install the udev rule (udev/90-halcyon-battery.rules, install.sh does it) and log in again." 2>/dev/null
  echo "$cur"; exit 1
fi
