#!/bin/bash
# Test run: a throw-away runtime dir so Halcyon cannot clash with another running session.
# (No user D-Bus / pipewire in there, so use halcyon.sh for daily use.)
export HYPRLAND_CONFIG="${HYPRLAND_CONFIG:-$HOME/.config/Halcyon}"
RUNTIME_DIR=/tmp/halcyon-runtime-$$
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export WAYLAND_DISPLAY="wayland-$$"

exec Hyprland
