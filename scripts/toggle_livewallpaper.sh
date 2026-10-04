#!/bin/bash

STATE_FILE="$HOME/.local/state/livewallpaper_disabled"
MONITOR="eDP-1"
WALLPAPER="$HOME/Pictures/Wallpapers/jinx-mayhem-in-arcane.3840x2160.mp4"

# Set Wayland display environment if not set (for udev/sudo/keybindings fallback)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
if [ -z "$WAYLAND_DISPLAY" ]; then
    if [ -S "$XDG_RUNTIME_DIR/wayland-1" ]; then
        export WAYLAND_DISPLAY="wayland-1"
    elif [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
        export WAYLAND_DISPLAY="wayland-0"
    else
        export WAYLAND_DISPLAY="wayland-1"
    fi
fi

if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    if ! pgrep -x gslapper >/dev/null; then
        gslapper --fork --cache-size 16 -l background -o "no-audio loop fill" "$MONITOR" "$WALLPAPER"
    fi
    notify-send "Live Wallpaper" "Enabled live wallpaper" -i video-display -h string:x-canonical-private-synchronous:livewallpaper
else
    touch "$STATE_FILE"
    pkill -9 gslapper
    notify-send "Live Wallpaper" "Disabled live wallpaper" -i video-display -h string:x-canonical-private-synchronous:livewallpaper
fi
