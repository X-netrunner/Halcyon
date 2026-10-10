#!/bin/sh
# SUPER+Q: close the top-most island overlay (settings, shortcuts, tree view, quick console, notifications, launcher,
# performance / media page, power menu); with nothing like that open, close the focused window as before.
r=$(quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island closeTop 2>/dev/null)
[ "$r" = "closed" ] && exit 0
exec hyprctl dispatch 'hl.dsp.window.close()'
