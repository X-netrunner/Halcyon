#!/usr/bin/env bash
# Tap Super alone -> open / close the launcher. Called by the release binds in hyprland/keybinds.lua.
# 1) fast path: write the trigger file the island watches with inotify (takes a few ms, 0 child processes)
# 2) fallback: ask the island over IPC only if the trigger file is absent
f="${XDG_RUNTIME_DIR:-/tmp}/halcyon-super-tap"
if [ -e "$f" ] && printf '%s\n' "$RANDOM$RANDOM" > "$f" 2>/dev/null; then
    exit 0
fi
printf '%s\n' "$RANDOM$RANDOM" > "$f" 2>/dev/null
exec quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island supertap >/dev/null 2>&1
