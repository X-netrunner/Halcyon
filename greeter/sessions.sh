#!/bin/sh
# Wayland sessions, one per line:  name <TAB> command <TAB> desktop names (DesktopNames=, ";"-separated, may be empty) <TAB> file id.
# Only the system folders (root-owned) are read, never anything in a home folder. The same session in both folders is listed once.
seen=" "
for f in /usr/local/share/wayland-sessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
  [ -f "$f" ] || continue
  grep -q '^\(Hidden\|NoDisplay\)=true' "$f" && continue
  id=$(basename "$f" .desktop)
  case "$seen" in *" $id "*) continue ;; esac
  seen="$seen$id "
  n=$(sed -n 's/^Name=//p' "$f" | head -n 1)
  e=$(sed -n 's/^Exec=//p' "$f" | head -n 1 | sed 's/ %[A-Za-z]//g')
  d=$(sed -n 's/^DesktopNames=//p' "$f" | head -n 1 | tr -cd 'A-Za-z0-9_.;:-')
  [ -n "$n" ] && [ -n "$e" ] && printf '%s\t%s\t%s\t%s\n' "$n" "$e" "$d" "$id"
done
exit 0
