#!/usr/bin/env bash
# extra-dim.sh: Toggle or set Extra Dim mode (drops screen backlight to minimum)
# Usage:
#   extra-dim.sh toggle
#   extra-dim.sh on
#   extra-dim.sh off
#   extra-dim.sh status

STATE_DIR="$HOME/.local/state/island"
STATE_FILE="$STATE_DIR/extra_dim.state"
mkdir -p "$STATE_DIR"

get_current_brightness() {
    if command -v brightnessctl >/dev/null 2>&1; then
        brightnessctl get 2>/dev/null || echo 100
    else
        for d in /sys/class/backlight/*; do
            if [ -r "$d/brightness" ]; then
                cat "$d/brightness"
                return
            fi
        done
        echo 100
    fi
}

set_brightness_val() {
    local val="$1"
    if command -v brightnessctl >/dev/null 2>&1; then
        brightnessctl set "$val" >/dev/null 2>&1 || true
    fi
}

cmd="${1:-toggle}"

case "$cmd" in
    on)
        if [ ! -f "$STATE_FILE" ]; then
            cur=$(get_current_brightness)
            echo "$cur" > "$STATE_FILE"
        fi
        set_brightness_val "1%"
        notify-send -a Halcyon -t 2000 "Extra Dim" "Screen brightness dimmed to minimum" 2>/dev/null || true
        echo "on"
        ;;
    off)
        if [ -f "$STATE_FILE" ]; then
            saved=$(cat "$STATE_FILE" 2>/dev/null || echo "35%")
            rm -f "$STATE_FILE"
            if [[ "$saved" =~ ^[0-9]+$ ]]; then
                set_brightness_val "$saved"
            else
                set_brightness_val "35%"
            fi
        else
            set_brightness_val "35%"
        fi
        notify-send -a Halcyon -t 2000 "Extra Dim" "Screen brightness restored" 2>/dev/null || true
        echo "off"
        ;;
    toggle)
        if [ -f "$STATE_FILE" ]; then
            exec "$0" off
        else
            exec "$0" on
        fi
        ;;
    status)
        if [ -f "$STATE_FILE" ]; then
            echo "on"
        else
            echo "off"
        fi
        ;;
    *)
        echo "usage: extra-dim.sh toggle | on | off | status" >&2
        exit 1
        ;;
esac
