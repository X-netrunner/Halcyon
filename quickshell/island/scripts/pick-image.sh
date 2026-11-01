#!/usr/bin/env bash
# Open a graphical file browser for an image and print the chosen path (nothing if cancelled).
#   $1 = folder or file to start from (optional)
# Native helper first: `hal pick-image` (src/hal). Exit 2 = an older hal that does not know it yet: the bash below still works.
hal="$(dirname "$(readlink -f "$0")")/../../../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  "$hal" pick-image "$@" && exit 0; rc=$?
  [ "$rc" -ne 2 ] && exit "$rc"
fi
start="${1:-$HOME/Pictures}"
case "$start" in "~"*) start="$HOME${start#\~}" ;; esac
[ -e "$start" ] || start="$HOME/Pictures"
[ -e "$start" ] || start="$HOME"
[ -d "$start" ] && start="${start%/}/"
if command -v zenity >/dev/null; then
  zenity --file-selection --title="Choose a profile picture" --filename="$start" \
    --file-filter="Images | *.png *.jpg *.jpeg *.webp *.gif *.bmp *.svg" --file-filter="All files | *" 2>/dev/null
elif command -v kdialog >/dev/null; then
  kdialog --getopenfilename "$start" "*.png *.jpg *.jpeg *.webp *.gif *.bmp *.svg|Images" 2>/dev/null
elif command -v yad >/dev/null; then
  yad --file --title="Choose a profile picture" --filename="$start" 2>/dev/null
else
  notify-send "Halcyon" "No file browser found (sudo pacman -S zenity)" 2>/dev/null
fi
exit 0
