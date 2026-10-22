#!/bin/bash
# Super + Alt + W: the live wallpaper on / off. The island plays it (Wallpaper.qml: the Halcyon sky, or a video / GIF from
# ~/Pictures/Wallpapers/live picked in Settings > Wallpaper > Live wallpaper), so nothing else has to be installed.
#   toggle_livewallpaper.sh            on <-> off
#   toggle_livewallpaper.sh <file|sky> switch to that one (and on)
ipc=(quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call wallpaper)
if [ -n "${1:-}" ]; then
    "${ipc[@]}" live "$1" >/dev/null 2>&1 || { notify-send -a Halcyon "Live wallpaper" "The island is not running"; exit 1; }
    exit 0
fi
now=$("${ipc[@]}" toggleLive 2>/dev/null) || { notify-send -a Halcyon "Live wallpaper" "The island is not running"; exit 1; }
notify-send -a Halcyon -i video-display -h string:x-canonical-private-synchronous:livewallpaper "Live wallpaper" "$([ "$now" = on ] && echo "On" || echo "Off: back to your picture")"
