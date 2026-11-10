#!/usr/bin/env bash
# Focus mode (advanced do-not-disturb with a timer and an app block list).
# Controlled via native helper `hx focus` (src/hx).
here="$(dirname "$(readlink -f "$0")")"
hx="$here/../bin/hx"; [ -x "$hx" ] || hx="$HOME/.config/Halcyon/bin/hx"
if [ -x "$hx" ]; then
  exec "$hx" focus "$@"
fi
echo "focus.sh: hx binary not found at $hx" >&2
exit 1
