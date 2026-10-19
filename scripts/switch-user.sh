#!/usr/bin/env bash
# switch-user.sh: what the lock screen's "Switch user" button runs. It uses systemd-logind, so it needs no root.
#
#   switch-user.sh list          other sessions on this seat, one per line:  SESSION_ID <TAB> USER <TAB> TTY
#   switch-user.sh to ID         bring that session to the front (it stays logged in; this screen stays locked)
#   switch-user.sh greeter       a login screen for someone else: lightdm's greeter if there is one, otherwise the next free
#                                text console (Ctrl+Alt+F2 ... F6) where getty asks for a login
#
# Switching users never unlocks THIS session: the lock screen stays up here, and you come back to it with the same password.
set -u

me="${XDG_SESSION_ID:-}"
have() { command -v "$1" >/dev/null 2>&1; }
say()  { have notify-send && notify-send -a Halcyon "Switch user" "$1" 2>/dev/null; printf '%s\n' "$1" >&2; }
prop() { loginctl show-session "$1" -p "$2" --value 2>/dev/null; }     # prop SESSION NAME

vtnr_of() { prop "$1" VTNr; }

case "${1:-}" in
  list)
    have loginctl || exit 0
    loginctl list-sessions --no-legend 2>/dev/null | while read -r id uid user seat tty _; do
      [ "$seat" = "seat0" ] || continue
      [ "$id" = "$me" ] && continue
      [ "$(prop "$id" Class)" = "user" ] || continue
      case "$(prop "$id" State)" in active|online) ;; *) continue ;; esac
      printf '%s\t%s\t%s\n' "$id" "$user" "${tty:-}"
    done ;;

  to)
    id="${2:-}"
    case "$id" in ''|*[!A-Za-z0-9_-]*) say "That is not a session id."; exit 2 ;; esac
    have loginctl || { say "loginctl is not installed."; exit 1; }
    loginctl activate "$id" 2>/dev/null || { say "Could not switch to session $id."; exit 1; } ;;

  greeter)
    if have dm-tool && dm-tool switch-to-greeter 2>/dev/null; then exit 0; fi
    have busctl && have loginctl || { say "Press Ctrl+Alt+F2 to reach a login prompt."; exit 1; }
    cur="$(vtnr_of "$me")"
    taken=" ${cur:-} "
    for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
      v="$(vtnr_of "$id")"; [ -n "$v" ] && [ "$v" != "0" ] && taken="$taken$v "
    done
    for n in 2 3 4 5 6; do
      case "$taken" in *" $n "*) continue ;; esac
      if busctl call org.freedesktop.login1 /org/freedesktop/login1/seat/seat0 org.freedesktop.login1.Seat SwitchTo u "$n" >/dev/null 2>&1; then exit 0; fi
      say "Could not open a login screen. Press Ctrl+Alt+F$n instead."; exit 1
    done
    say "Every text console is in use. Press Ctrl+Alt+F2 to reach one."; exit 1 ;;

  -h|--help|"") sed -n 2,9p "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "switch-user.sh: unknown command $1" >&2; exit 2 ;;
esac
