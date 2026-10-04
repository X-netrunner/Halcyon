#!/bin/bash
LOCK_FILE="/dev/shm/touchpad_music_gestures_disabled"
if [ -f "$LOCK_FILE" ]; then
    rm "$LOCK_FILE"
    notify-send "Music Gestures" "Enabled" -i input-touchpad
else
    touch "$LOCK_FILE"
    notify-send "Music Gestures" "Disabled" -i input-touchpad
fi
