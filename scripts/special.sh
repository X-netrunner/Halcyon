#!/usr/bin/env bash
# special.sh <name> [--show]      SUPER+M (music), SUPER+D (communication) and the bar / background-apps "Open" buttons.
#   - the special workspace <name> has no windows yet  ->  start its app, and show the workspace so the window lands in view
#   - it has windows                                   ->  toggle it (--show: only ever show it, never hide)
# Which app each workspace starts is set here, or in ~/.config/Halcyon/special.conf (plain shell, overrides these):
#   MUSIC_CMD='spotify'
#   COMM_CMD='vesktop'
# SPECIAL_CMD in the environment overrides both (the background-apps box uses it to open one specific app).
name="${1:?usage: special.sh <name> [--show]}"; show=0; [ "$2" = "--show" ] && show=1

MUSIC_CMD="sh -c 'command -v spotify >/dev/null && exec spotify; command -v spotify-launcher >/dev/null && exec spotify-launcher; exec ~/.config/Halcyon/scripts/apps.sh term-exec ncmpcpp'"
COMM_CMD="sh -c 'command -v vesktop >/dev/null && exec vesktop; exec discord'"
[ -f "$HOME/.config/Halcyon/special.conf" ] && . "$HOME/.config/Halcyon/special.conf"

case "$name" in
  music)         cmd="$MUSIC_CMD" ;;
  communication) cmd="$COMM_CMD" ;;
  *)             cmd="" ;;
esac
[ -n "$SPECIAL_CMD" ] && cmd="$SPECIAL_CMD"

toggle() { hyprctl dispatch "hl.dsp.workspace.toggle_special(\"$name\")" >/dev/null 2>&1; }
visible=0; hyprctl monitors 2>/dev/null | grep -q "special workspace: .*(special:$name)" && visible=1
count=$(hyprctl clients 2>/dev/null | grep -c "workspace: .*(special:$name)")

if [ "$visible" = 1 ]; then
  [ "$show" = 1 ] || toggle          # already showing: SUPER+M again hides it
  [ "$count" = 0 ] && [ -n "$cmd" ] && setsid -f bash -c "$cmd" >/dev/null 2>&1   # showing but empty: start the app
  exit 0
fi
toggle
[ "$count" = 0 ] && [ -n "$cmd" ] && setsid -f bash -c "$cmd" >/dev/null 2>&1
exit 0
