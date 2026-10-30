#!/usr/bin/env bash
# floating-mode.sh on | off | toggle | status
# Controlled via native helper `hal floating-mode` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" floating-mode "$@"
fi

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/island"
FLAG="$STATE/float-all"
LIST="$STATE/float-all.list"
mkdir -p "$STATE"

is_on() { [ "$(head -n1 "$FLAG" 2>/dev/null)" = "1" ]; }

clients() {
    hyprctl clients -j 2>/dev/null | python3 -c '
import json, sys
try:
    cs = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for c in cs:
    if c.get("mapped") and c.get("workspace", {}).get("id", 0) > 0 and not c.get("pinned"):
        print(c["address"], 1 if c.get("floating") else 0, c.get("class", ""), c.get("title", ""))
'
}

toggle_float() {
    hyprctl dispatch "hl.dsp.window.float({ window = \"address:$1\" })" >/dev/null 2>&1
}

set_rule() {
    hyprctl eval "if halcyon_float_all then halcyon_float_all:set_enabled($1) end" >/dev/null 2>&1
}

case "${1:-status}" in
    on)
        printf '1\n' > "$FLAG"
        set_rule true
        : > "$LIST"
        clients | while read -r addr fl cls ttl; do
            [ "$fl" = 0 ] || continue
            toggle_float "$addr"
            printf '%s\n' "$addr" >> "$LIST"
        done
        ;;
    off)
        printf '0\n' > "$FLAG"
        set_rule false
        saved=""
        [ -s "$LIST" ] && saved=$(cat "$LIST")
        clients | while read -r addr fl cls ttl; do
            [ "$fl" = 1 ] || continue
            case "$cls" in
                pavucontrol|blueman-manager|nm-connection-editor|qalculate-gtk|gnome-calculator|org.gnome.Calculator|file-roller|org.gnome.FileRoller|ark|hyprland-share-picker|xdg-desktop-portal-gtk|zenity|yad|*polkit*|org.quickshell|mpv)
                    continue
                    ;;
            esac
            case "$ttl" in
                *Picture-in-Picture*)
                    continue
                    ;;
            esac
            toggle_float "$addr"
        done
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
