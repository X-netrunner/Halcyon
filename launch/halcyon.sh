#!/bin/bash
# Start Halcyon through the Hyprland start wrapper (normal way to launch it from a TTY).
export HYPRLAND_CONFIG="${HYPRLAND_CONFIG:-$HOME/.config/Halcyon}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
exec /usr/bin/start-hyprland
