#!/bin/bash
# Toggle the touchpad (Hyprland device). The touchpad is looked up by name; nothing is guessed.
# (It used to fall back to the author's own touchpad, "elan07fb:00-04f3:321a-touchpad": on any other laptop the toggle then did
#  nothing but still showed "Disabled" / "Enabled", and the saved state went out of step with the real one.)
DEVICE=$(hyprctl devices -j 2>/dev/null | grep -i '"name":' | grep -i 'touchpad' | head -1 | sed -E 's/.*"name": *"([^"]+)".*/\1/')
if [ -z "$DEVICE" ]; then
    notify-send "Touchpad" "No touchpad found" -i input-touchpad 2>/dev/null
    exit 1
fi
STATUS_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/touchpad.status"

# Default state if file doesn't exist
[ -f "$STATUS_FILE" ] || echo "enabled" > "$STATUS_FILE"

CURRENT_STATE=$(cat "$STATUS_FILE")

if [ "$CURRENT_STATE" = "enabled" ]; then
    NEW=disabled; FLAG=false
else
    NEW=enabled; FLAG=true
fi
# only report (and remember) the new state when Hyprland really accepted it
if hyprctl eval "hl.device({ name = \"$DEVICE\", enabled = $FLAG })" >/dev/null 2>&1; then
    echo "$NEW" > "$STATUS_FILE"
    notify-send "Touchpad" "${NEW^}" -i input-touchpad
else
    notify-send "Touchpad" "Could not switch it (hyprctl failed)" -i input-touchpad
    exit 1
fi
