#!/bin/sh
# Tap Super alone -> open / close the launcher.
# Controlled via native helper `hal supertap` (src/hal), with in-script fallback.
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  "$hal" supertap "$@"; rc=$?
  [ "$rc" -ne 2 ] && exit "$rc"
fi
d="${XDG_RUNTIME_DIR:-/tmp}"
f="$d/halcyon-super-tap"
ack="$d/halcyon-super-ack"
dbg="$HOME/.cache/island/super-debug"
[ -e "$dbg" ] && echo "$(date +%T.%N) tap: write trigger" >> "$dbg.log"
printf '%s\n' "$$" > "$f" 2>/dev/null
i=0
while [ "$i" -lt 5 ]; do
  [ "$ack" -nt "$f" ] && { [ -e "$dbg" ] && echo "$(date +%T.%N) tap: island answered" >> "$dbg.log"; exit 0; }
  sleep 0.03
  i=$((i + 1))
done
[ -e "$dbg" ] && echo "$(date +%T.%N) tap: no answer, using IPC" >> "$dbg.log"
exec quickshell ipc -p "$HOME/.config/Halcyon/quickshell/island" call island supertap >/dev/null 2>&1
