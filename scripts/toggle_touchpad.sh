#!/bin/bash
DEVICE=$(hyprctl devices -j 2>/dev/null | grep -i '"name":' | grep -i 'touchpad' | head -1 | sed -E 's/.*"name": *"([^"]+)".*/\1/')
[ -n "$DEVICE" ] || DEVICE="elan07fb:00-04f3:321a-touchpad"
STATUS_FILE="$XDG_RUNTIME_DIR/touchpad.status"

# Default state if file doesn't exist
if [ ! -f "$STATUS_FILE" ]; then
    echo "enabled" > "$STATUS_FILE"
fi

CURRENT_STATE=$(cat "$STATUS_FILE")

if [ "$CURRENT_STATE" = "enabled" ]; then
    hyprctl eval "hl.device({ name = \"$DEVICE\", enabled = false })"
    echo "disabled" > "$STATUS_FILE"
    notify-send "Touchpad" "Disabled" -i input-touchpad
else
    hyprctl eval "hl.device({ name = \"$DEVICE\", enabled = true })"
    echo "enabled" > "$STATUS_FILE"
    notify-send "Touchpad" "Enabled" -i input-touchpad
fi
