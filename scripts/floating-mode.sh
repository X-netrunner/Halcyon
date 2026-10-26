#!/bin/bash
# floating-mode.sh on | off | toggle | status
# Settings > Workspaces & windows > "No tiling": every window opens floating and keeps its own size and place, like an ordinary
# window manager. hyprland/rules.lua reads the flag file at every start / reload and keeps one rule (halcyon_float_all) that this script
# switches on and off live; windows that are already open are floated now (and tiled again on "off" - only the ones this script floated,
# so mpv, Picture-in-Picture and the other windows that float by their own rule stay as they are).
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/island"
FLAG="$STATE/float-all"
LIST="$STATE/float-all.list"
mkdir -p "$STATE"

is_on() { [ "$(head -n1 "$FLAG" 2>/dev/null)" = "1" ]; }

# every window of the normal workspaces: "address floating" per line (special workspaces and the island's own windows are left alone)
clients() {
    hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    cs = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for c in cs:
    if c.get("mapped") and c.get("workspace", {}).get("id", 0) > 0 and not c.get("pinned"):
        print(c["address"], 1 if c.get("floating") else 0)
'
}

toggle_float() {   # no action word: the dispatcher flips it, and we know the state before
    hyprctl dispatch "hl.dsp.window.float({ window = \"address:$1\" })" >/dev/null 2>&1
}

set_rule() {       # $1 = true | false
    hyprctl eval "if halcyon_float_all then halcyon_float_all:set_enabled($1) end" >/dev/null 2>&1
}

case "${1:-status}" in
    on)
        printf '1\n' > "$FLAG"
        set_rule true
        : > "$LIST"
        clients | while read -r addr fl; do
            [ "$fl" = 0 ] || continue
            toggle_float "$addr"
            printf '%s\n' "$addr" >> "$LIST"
        done
        ;;
    off)
        printf '0\n' > "$FLAG"
        set_rule false
        if [ -s "$LIST" ]; then
            clients | while read -r addr fl; do
                [ "$fl" = 1 ] || continue
                grep -qx "$addr" "$LIST" && toggle_float "$addr"
            done
        fi
        : > "$LIST"
        ;;
    toggle)
        if is_on; then exec "$0" off; else exec "$0" on; fi
        ;;
    status)
        if is_on; then echo on; else echo off; fi
        ;;
    *)
        echo "usage: floating-mode.sh on|off|toggle|status" >&2
        exit 2
        ;;
esac
