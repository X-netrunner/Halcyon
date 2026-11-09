#!/usr/bin/env bash
# The battery percentage of the first connected Bluetooth device that reports one (headphones, mouse, keyboard ...).
# Prints just the number, or nothing when no connected device tells its battery. Run by the utilities box while it is open.

hal="$(dirname "$(readlink -f "$0")")/../../../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" bt-battery "$@"
fi

while read -r _ mac _; do
  [ -n "$mac" ] || continue
  while IFS= read -r l; do
    case "$l" in
      *"Battery Percentage"*) l=${l##*(}; printf '%s\n' "${l%%)*}"; exit 0 ;;
    esac
  done < <(bluetoothctl info "$mac" 2>/dev/null)
done < <(bluetoothctl devices Connected 2>/dev/null)
exit 0
