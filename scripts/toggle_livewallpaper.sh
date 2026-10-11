#!/bin/bash

STATE_FILE="$HOME/.local/state/livewallpaper_disabled"

# monitor: the laptop panel (eDP-*) if there is one, else the first one Hyprland reports (override: HALCYON_MONITOR)
MONITOR="${HALCYON_MONITOR:-$(hyprctl monitors 2>/dev/null | awk '/^Monitor/ {n=$2; if (n ~ /^eDP/) {print n; found=1; exit} if (first=="") first=n} END {if (!found) print first}')}"
MONITOR="${MONITOR:-eDP-1}"

# wallpaper: a random video from ~/Pictures/Wallpapers/live (same folder the power manager uses; override: HALCYON_LIVE_WALLPAPER)
WALLPAPER="${HALCYON_LIVE_WALLPAPER:-$(find "$HOME/Pictures/Wallpapers/live" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \) 2>/dev/null | shuf -n1)}"

# Set Wayland display environment if not set (for udev/sudo/keybindings fallback)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
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
    if [ -z "$WALLPAPER" ]; then
        notify-send "Live Wallpaper" "No video found in ~/Pictures/Wallpapers/live" -i video-display -h string:x-canonical-private-synchronous:livewallpaper
    elif ! pgrep -x gslapper >/dev/null; then
        gslapper --fork --cache-size 16 -l background -o "no-audio loop fill" "$MONITOR" "$WALLPAPER"
    fi
    notify-send "Live Wallpaper" "Enabled live wallpaper" -i video-display -h string:x-canonical-private-synchronous:livewallpaper
else
    touch "$STATE_FILE"
    pkill -9 gslapper
    notify-send "Live Wallpaper" "Disabled live wallpaper" -i video-display -h string:x-canonical-private-synchronous:livewallpaper
fi
