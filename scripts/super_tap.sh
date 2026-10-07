#!/usr/bin/env bash
# Tap Super alone -> open / close the launcher. Called by the release binds in hyprland/keybinds.lua.
# 1) fast path: write the trigger file the island watches with inotify (takes a few ms)
# 2) fallback: ask the island over IPC (a whole `quickshell` process starts, so ~100ms+); the island ignores
#    the second trigger when the fast path already worked (debounce in shell.qml, superTapFired)
# The "Tap Super to open the launcher" switch is checked inside the island, so nothing is read from disk here.
f="${XDG_RUNTIME_DIR:-/tmp}/halcyon-super-tap"
printf '%s\n' "$RANDOM$RANDOM" > "$f" 2>/dev/null
exec quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island supertap >/dev/null 2>&1
