#!/usr/bin/env bash
# Started once by hyprland/execs.lua. Starts the polkit agent (the lightest installed one) and, only if asked, the tray applets.
# Settings: ~/.config/Halcyon/autostart.conf   (created on first run)
#   NM_APPLET=0      1 = start nm-applet    (tray icon + VPN / 802.1x password prompts; plain Wi-Fi is handled by the island)
#   BLUEMAN=0        1 = start blueman-applet (needed to PAIR new Bluetooth devices from a GUI; paired devices reconnect without it)
#   POLKIT=auto      auto | hyprpolkitagent | gnome | kde | none
conf="$HOME/.config/Halcyon/autostart.conf"
if [ ! -f "$conf" ]; then
  mkdir -p "$(dirname "$conf")"
  printf 'NM_APPLET=0\nBLUEMAN=0\nPOLKIT=auto\n' > "$conf"
fi
NM_APPLET=0; BLUEMAN=0; POLKIT=auto
. "$conf" 2>/dev/null

first_exec() { for p in "$@"; do [ -x "$p" ] && { echo "$p"; return 0; }; done; return 1; }
agent=""
case "$POLKIT" in
  none) ;;
  hyprpolkitagent) agent=$(first_exec /usr/lib/hyprpolkitagent/hyprpolkitagent) ;;
  gnome) agent=$(first_exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/libexec/polkit-gnome-authentication-agent-1) ;;
  kde)   agent=$(first_exec /usr/lib/polkit-kde-authentication-agent-1 /usr/libexec/polkit-kde-authentication-agent-1) ;;
  *)     agent=$(first_exec /usr/lib/hyprpolkitagent/hyprpolkitagent \
                            /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/libexec/polkit-gnome-authentication-agent-1 \
                            /usr/lib/polkit-kde-authentication-agent-1 /usr/libexec/polkit-kde-authentication-agent-1) ;;
esac
[ -n "$agent" ] && { setsid -f "$agent" >/dev/null 2>&1 </dev/null; }
if [ "$NM_APPLET" = 1 ] && command -v nm-applet >/dev/null 2>&1; then sleep 2; setsid -f nm-applet >/dev/null 2>&1 </dev/null; fi
if [ "$BLUEMAN" = 1 ] && command -v blueman-applet >/dev/null 2>&1; then sleep 1; setsid -f blueman-applet >/dev/null 2>&1 </dev/null; fi
exit 0
