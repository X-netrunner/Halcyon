#!/bin/bash
DEVICE="ascf1201:00-2808:0231-touchpad"
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
