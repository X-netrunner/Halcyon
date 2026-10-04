#!/bin/bash
# SUPER+ALT+N: blue-light filter on/off (needs hyprsunset). Colour temperature: NIGHTLIGHT_TEMP (default 4000 K).
TEMP="${NIGHTLIGHT_TEMP:-4000}"

if pgrep -x hyprsunset >/dev/null; then
    pkill -x hyprsunset
    notify-send "Nightlight" "Off" -i weather-clear -h string:x-canonical-private-synchronous:nightlight
elif command -v hyprsunset >/dev/null; then
    setsid hyprsunset -t "$TEMP" >/dev/null 2>&1 &
    notify-send "Nightlight" "On (${TEMP}K)" -i weather-clear-night -h string:x-canonical-private-synchronous:nightlight
else
    notify-send "Nightlight" "hyprsunset is not installed (pacman -S hyprsunset)" -i dialog-warning
fi
