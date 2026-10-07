#!/bin/bash
# Start Halcyon (Hyprland with the Halcyon config) from a TTY, the login screen ("Halcyon" session) or start-halcyon.
#
# HYPRLAND_CONFIG has to name the config FILE (hyprland.lua), never the Halcyon folder. Hyprland takes that variable as
# "the" config file and prefers it over ~/.config/hypr/hyprland.lua; pointing it at a folder makes Hyprland fail to read
# its config and start with its built-in defaults (no island, no keybinds, nothing of Halcyon). That is what this script
# used to do. It now:
#   - finds the Halcyon folder from its own location,
#   - points HYPRLAND_CONFIG at <folder>/hyprland.lua (a folder value, from you or an old setup, is corrected),
#   - writes a short log to ~/.cache/island/launch.log (what it started, which config, which Hyprland).
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RICE="${HALCYON_DIR:-$(dirname "$here")}"
[ -f "$RICE/hyprland.lua" ] || RICE="$HOME/.config/Halcyon"

cfg="${HYPRLAND_CONFIG:-}"
[ -d "$cfg" ] && cfg="${cfg%/}/hyprland.lua"          # a folder is not a config: use the file inside it
[ -n "$cfg" ] && [ -f "$cfg" ] || cfg="$RICE/hyprland.lua"
export HYPRLAND_CONFIG="$cfg"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 700 "$XDG_RUNTIME_DIR"; fi
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_DESKTOP=Hyprland

mkdir -p "$HOME/.cache/island" 2>/dev/null
log="$HOME/.cache/island/launch.log"
{
  echo "== $(date '+%F %T')  halcyon.sh  config=$cfg"
  command -v Hyprland >/dev/null 2>&1 && Hyprland --version 2>/dev/null | head -n1
  command -v quickshell >/dev/null 2>&1 || echo "WARNING: quickshell is not installed (sudo pacman -S quickshell)"
} >> "$log" 2>&1

if [ ! -f "$cfg" ]; then
  echo "Halcyon: config not found: $cfg" | tee -a "$log" >&2
  echo "Run the installer again:  ./install.sh   (from the Halcyon folder)" >&2
  sleep 5; exit 1
fi

if command -v start-hyprland >/dev/null 2>&1; then exec start-hyprland; fi     # Hyprland's own start wrapper (0.53 and newer)
if command -v Hyprland >/dev/null 2>&1; then exec Hyprland; fi
echo "Halcyon: Hyprland is not installed (sudo pacman -S hyprland), then run ./install.sh" | tee -a "$log" >&2
sleep 5; exit 1
