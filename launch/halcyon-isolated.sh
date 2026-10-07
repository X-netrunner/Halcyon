#!/bin/bash
# Test run: a throw-away runtime dir so Halcyon cannot clash with another running session.
# (No user D-Bus / pipewire in there, so use halcyon.sh for daily use.)
# HYPRLAND_CONFIG names the config FILE (see launch/halcyon.sh), not the folder.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RICE="${HALCYON_DIR:-$(dirname "$here")}"
[ -f "$RICE/hyprland.lua" ] || RICE="$HOME/.config/Halcyon"
cfg="${HYPRLAND_CONFIG:-}"
[ -d "$cfg" ] && cfg="${cfg%/}/hyprland.lua"
[ -n "$cfg" ] && [ -f "$cfg" ] || cfg="$RICE/hyprland.lua"
export HYPRLAND_CONFIG="$cfg"

RUNTIME_DIR=/tmp/halcyon-runtime-$$
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export WAYLAND_DISPLAY="wayland-$$"

exec Hyprland
