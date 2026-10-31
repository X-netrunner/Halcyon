#!/bin/sh
# polkit-agent.sh: make sure a polkit agent (the program that shows the "enter your password" window) is running in this session.
# Used by the Security center before it asks for a password with pkexec: without an agent pkexec fails at once with
# "No authentication agent found" and nothing is shown. Prints  running | started NAME | none  and exits 0, or 1 for none.
#
#   polkit-agent.sh          check, and start one if none is running (the lightest installed: Hyprland's, GNOME's, KDE's)
#   polkit-agent.sh check    only check
#
# Not started when Settings > Startup chose "None" for the polkit agent (POLKIT=none): that choice is respected, and the answer
# is "none" so the Security center can say why no password window can appear.
conf="$HOME/.config/Halcyon/autostart.conf"        # the same file scripts/autostart-extras.sh reads (Settings > Startup writes it)
POLKIT=auto
[ -f "$conf" ] && . "$conf" 2>/dev/null

command -v pkexec >/dev/null 2>&1 || { echo nopkexec; exit 1; }
running() { pgrep -u "$(id -u)" -f 'hyprpolkitagent|polkit-gnome-authentication-agent|polkit-kde-authentication-agent|lxqt-policykit|mate-polkit|polkit-mate-authentication-agent|xfce-polkit|polkit-dumb-agent|soteria|lxpolkit' >/dev/null 2>&1; }

if running; then echo running; exit 0; fi
[ "${1:-}" = check ] && { echo none; exit 1; }
[ "$POLKIT" = none ] && { echo none; exit 1; }

first_exec() { for p in "$@"; do [ -x "$p" ] && { echo "$p"; return 0; }; done; return 1; }
H=/usr/lib/hyprpolkitagent/hyprpolkitagent
G="/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/libexec/polkit-gnome-authentication-agent-1 /usr/lib/x86_64-linux-gnu/polkit-gnome-authentication-agent-1"
K="/usr/lib/polkit-kde-authentication-agent-1 /usr/libexec/polkit-kde-authentication-agent-1 /usr/lib/x86_64-linux-gnu/libexec/polkit-kde-authentication-agent-1"
case "$POLKIT" in
  hyprpolkitagent) agent=$(first_exec $H) ;;
  gnome)           agent=$(first_exec $G) ;;
  kde)             agent=$(first_exec $K) ;;
  *)               agent=$(first_exec $H $G $K) ;;
esac
[ -n "${agent:-}" ] || agent=$(first_exec $H $G $K)      # the chosen one is not installed: any installed one is better than none
[ -n "${agent:-}" ] || { echo none; exit 1; }
setsid -f "$agent" >/dev/null 2>&1 </dev/null
i=0
while [ "$i" -lt 20 ]; do
  running && { echo "started $(basename "$agent")"; exit 0; }
  sleep 0.2; i=$((i + 1))
done
echo none; exit 1
