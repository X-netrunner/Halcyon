#!/bin/bash
# Start Halcyon from tty1 with the lock screen already on, so the lock screen is the login screen.
# Used by the profile snippet that install.sh writes when the machine has no display manager (sddm, gdm, ...),
# together with an auto-login on tty1 (see install.sh --lock-login). Run it by hand from a TTY to try the same thing.
#
# Safety:
#   * the island locks itself the moment it starts (quickshell/island/shell.qml reads the flag file made below);
#     scripts/login-watchdog.sh then makes sure of it: no lock within ~20 s = Hyprland is ended, never left open
#   * crash-loop guard: three starts within 90 seconds and it stops trying (a message, a 30 s pause, then log out) so a broken
#     config cannot spin forever. Switch to another tty (Ctrl+Alt+F2), fix ~/.config/Halcyon, and it works again
#   * opt out any time:  touch ~/.cache/island/no-autostart   (then tty1 is an ordinary shell)
state="$HOME/.cache/island"
mkdir -p "$state"
if [ -e "$state/no-autostart" ]; then
  echo "Halcyon autostart is off (remove $state/no-autostart to turn it on)."
  exit 0
fi
guard="/tmp/halcyon-login-$(id -u)"        # lives until the next reboot
now=$(date +%s); recent=0
if [ -f "$guard" ]; then
  while read -r t; do [ -n "$t" ] && [ $((now - t)) -lt 90 ] && recent=$((recent + 1)); done < "$guard"
fi
echo "$now" >> "$guard"
if [ "$recent" -ge 3 ]; then
  rm -f "$state/lock-on-start"
  echo
  echo "Halcyon did not stay up (3 starts in 90 seconds), so it is not starting again."
  echo "Press Ctrl+Alt+F2 for another console, log in there and look at ~/.config/Halcyon (journalctl --user -e)."
  echo "This console logs out in 30 seconds."
  sleep 30
  exit 1
fi
: > "$state/lock-on-start"                  # the island takes this file and locks first thing
exec "$(dirname "$(readlink -f "$0")")/halcyon.sh"
