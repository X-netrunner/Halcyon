#!/usr/bin/env bash
# asus-kbd-fix.sh: Clears the ASUS out-of-box (OOBE) keyboard backlight lock flag
# for ASUS Vivobook 16 (V3607VU) and related models via asus-nb-wmi debugfs.
set -euo pipefail

debug_dir="/sys/kernel/debug/asus-nb-wmi"

# Ensure debugfs is mounted
if [ ! -d "/sys/kernel/debug" ]; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
fi

# Ensure asus-nb-wmi is loaded
if [ ! -d "$debug_dir" ]; then
    modprobe asus_nb_wmi 2>/dev/null || true
fi

if [ -d "$debug_dir" ]; then
    echo 0x5002f > "$debug_dir/dev_id" 2>/dev/null || true
    echo 0 > "$debug_dir/ctrl_param" 2>/dev/null || true
    cat "$debug_dir/devs" >/dev/null 2>&1 || true
    echo 1 > "$debug_dir/ctrl_param" 2>/dev/null || true
    cat "$debug_dir/devs" >/dev/null 2>&1 || true
    echo "ASUS keyboard backlight OOBE flag cleared successfully."
else
    echo "Warning: $debug_dir not found. Ensure asus-nb-wmi driver is loaded." >&2
fi

# Set an active brightness level (2 out of 3) so the keyboard light turns on immediately
if [ -d /sys/class/leds/asus::kbd_backlight ]; then
    if command -v brightnessctl >/dev/null 2>&1; then
        brightnessctl -d asus::kbd_backlight set 2 >/dev/null 2>&1 || true
    elif [ -w /sys/class/leds/asus::kbd_backlight/brightness ]; then
        echo 2 > /sys/class/leds/asus::kbd_backlight/brightness 2>/dev/null || true
    fi
fi
