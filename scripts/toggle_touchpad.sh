#!/bin/bash
# Toggle the touchpad (Hyprland device). The touchpad is looked up by name; nothing is guessed.
# (It used to fall back to the author's own touchpad, "elan07fb:00-04f3:321a-touchpad": on any other laptop the toggle then did
#  nothing but still showed "Disabled" / "Enabled", and the saved state went out of step with the real one.)
DEVICE=$(hyprctl devices -j 2>/dev/null | grep -i '"name":' | grep -i 'touchpad' | head -1 | sed -E 's/.*"name": *"([^"]+)".*/\1/')
if [ -z "$DEVICE" ]; then
    notify-send "Touchpad" "No touchpad found" -i input-touchpad 2>/dev/null
    exit 1
fi
# The name goes into Lua code that hyprctl evals inside the compositor. A name with a quote, a backslash or a control character
# would break that code (or inject some), so only a plain set of characters is accepted; anything else is refused, not cleaned
# (a cleaned name would not match the device any more).
case "$DEVICE" in
    *[!A-Za-z0-9\ _:./+@\(\)-]*)
        notify-send "Touchpad" "The touchpad name has characters that are not safe to pass on, so nothing was changed" -i input-touchpad 2>/dev/null
        echo "toggle_touchpad: refusing unsafe device name: $DEVICE" >&2
        exit 1 ;;
esac
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
