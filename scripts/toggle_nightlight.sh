#!/bin/bash
# SUPER+ALT+N: blue-light filter on/off (needs hyprsunset).
#   toggle_nightlight.sh            on / off
#   toggle_nightlight.sh on | off   set it
#   toggle_nightlight.sh temp <K>   change the colour temperature (restarts the filter when it is on)
# Colour temperature: Settings > Tools > Night light warmth (~/.local/state/island/nightlight-temp), else NIGHTLIGHT_TEMP,
# else 4000 K.
state="$HOME/.local/state/island"
mkdir -p "$state"
TEMP="${NIGHTLIGHT_TEMP:-4000}"
saved=$(head -n1 "$state/nightlight-temp" 2>/dev/null)
case "$saved" in ''|*[!0-9]*) ;; *) TEMP="$saved" ;; esac

start() {
    pkill -x hyprsunset 2>/dev/null
    setsid hyprsunset -t "$TEMP" >/dev/null 2>&1 &
}
say() { notify-send "Nightlight" "$1" -i "$2" -h string:x-canonical-private-synchronous:nightlight; }
have() { command -v hyprsunset >/dev/null; }
running() { pgrep -x hyprsunset >/dev/null; }

case "${1:-toggle}" in
    temp)
        case "$2" in ''|*[!0-9]*) exit 1 ;; esac
        TEMP="$2"; printf '%s\n' "$TEMP" > "$state/nightlight-temp"
        running && have && start               # already on: switch to the new warmth right away (no popup while dragging)
        exit 0 ;;
    on)  running && exit 0; want=on ;;
    off) running || exit 0; want=off ;;
    *)   if running; then want=off; else want=on; fi ;;
esac

if [ "$want" = off ]; then
    pkill -x hyprsunset
    say "Off" weather-clear
elif have; then
    start
    say "On (${TEMP}K)" weather-clear-night
else
    notify-send "Nightlight" "hyprsunset is not installed (pacman -S hyprsunset)" -i dialog-warning
fi
