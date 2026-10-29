#!/usr/bin/env bash
# Controlled via native helper `hal toggle-power` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" toggle-power "$@"
fi

SERVICE_NAME="power-manager.service"
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

if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    systemctl --user stop "$SERVICE_NAME"
    notify-send "Power Manager" "Disabled (Manual Mode)" -i battery-caution -h string:x-canonical-private-synchronous:powermanager
else
    systemctl --user start "$SERVICE_NAME"
    notify-send "Power Manager" "Enabled (Automatic Mode)" -i battery -h string:x-canonical-private-synchronous:powermanager
fi
