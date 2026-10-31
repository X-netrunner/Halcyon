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
# Started by the Halcyon login manager (greeter/shell.qml sets HALCYON_FROM_GREETER): the password was already typed there, so
# this is NOT the tty1 auto-login. A profile snippet left over from it must not lock the desktop a second time or arm the watchdog
# (which ends Hyprland when the lock never engages): drop the flag and start the desktop as it is.
if [ "${HALCYON_FROM_GREETER:-}" = 1 ]; then
  rm -f "$state/lock-on-start"
  exec "$(dirname "$(readlink -f "$0")")/halcyon.sh"
fi
# The boot splash is still on screen (Plymouth leaves its last frame until Hyprland draws, and the tty1 getty does not reset the
# console): no cursor, no echo of keys pressed while it loads. text_console brings the text back before anything is printed.
if [ -t 0 ]; then printf '\033[?25l'; stty -echo 2>/dev/null; fi
text_console() {   # KDSETMODE (0x4B3A) KD_TEXT, cursor and echo back on
  python3 -c 'import fcntl; fcntl.ioctl(0, 0x4B3A, 0)' 2>/dev/null
  printf '\033[?25h'; stty echo 2>/dev/null
}
if [ -e "$state/no-autostart" ]; then
  text_console
  echo "Halcyon autostart is off (remove $state/no-autostart to turn it on)."
  exit 0
fi
guard="$state/login-guard"                 # in your own cache folder: no shared /tmp name for someone else to pre-create, and it survives the logout this guard causes (entries older than 90 s are ignored anyway)
now=$(date +%s); recent=0; kept=""
if [ -f "$guard" ]; then
  while read -r t; do
    case "$t" in ''|*[!0-9]*) continue ;; esac
    if [ $((now - t)) -lt 90 ]; then
      recent=$((recent + 1))
      kept="${kept}${t}"$'\n'
    fi
  done < "$guard"
fi
printf '%s%s\n' "$kept" "$now" > "$guard"
if [ "$recent" -ge 3 ]; then
  rm -f "$state/lock-on-start"
  text_console
  echo
  echo "Halcyon did not stay up (3 starts in 90 seconds), so it is not starting again."
  echo "Press Ctrl+Alt+F2 for another console, log in there and look at ~/.config/Halcyon (journalctl --user -e)."
  echo "This console logs out in 30 seconds."
  sleep 30
  exit 1
fi
: > "$state/lock-on-start"                  # the island takes this file and locks first thing
# read by the island the moment it starts (no file read needed): it keeps the desktop hidden until the lock screen is up, so the
# desktop never shows for a frame between the boot splash and the lock. Also: Hyprland's start-up text goes to a log, not tty1.
export HALCYON_LOGIN_LOCK=1
exec "$(dirname "$(readlink -f "$0")")/halcyon.sh"
