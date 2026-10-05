#!/usr/bin/env bash
# Open a graphical file browser for an image and print the chosen path (nothing if cancelled).
#   $1 = folder or file to start from (optional)
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
