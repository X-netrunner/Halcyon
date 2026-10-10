#!/usr/bin/env bash
# The cheatsheet is a tree inside the island now (quickshell/island/Cheatsheet.qml, data in Binds.js):
# SUPER+/  |  launcher: ">shortcuts"  |  Settings > Shortcuts. This script just asks the island to show it.
# If the island is not running it falls back to a plain fuzzel list of the defaults.
if quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island cheatsheet >/dev/null 2>&1; then exit 0; fi
pkill -f 'fuzzel.*--prompt=Keys' 2>/dev/null && exit 0
node_list=$(grep -o 'label: "[^"]*", keys: "[^"]*"' "$HOME/.config/Halcyon/quickshell/island/Binds.js" | sed 's/label: "\(.*\)", keys: "\(.*\)"/\2   \1/')
printf '%s\n' "$node_list" | fuzzel --dmenu --prompt="Keys > " --lines=18 --width=72
