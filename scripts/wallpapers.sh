#!/usr/bin/env bash
# Wallpaper folder helper (Settings > Wallpaper). The folder is ~/Pictures/Wallpapers unless you pick another one.
#   wallpapers.sh dir            print the folder (made if it does not exist)
#   wallpapers.sh list           JSON: folder, the wallpaper in use, and every image in it
#   wallpapers.sh open           open the folder in your file manager (drop images in there)
#   wallpapers.sh add            pick image files and copy them into the folder (zenity / kdialog / yad; else opens the folder)
#   wallpapers.sh choose-dir     pick a different folder (same pickers)
#   wallpapers.sh reset-dir      back to ~/Pictures/Wallpapers
state="$HOME/.local/state/island"; dirf="$state/wallpaper.dir"; cur="$state/wallpaper"
mkdir -p "$state"
dir="$HOME/Pictures/Wallpapers"
[ -s "$dirf" ] && dir=$(head -n1 "$dirf")
mkdir -p "$dir" 2>/dev/null

json() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
note() { notify-send -a Halcyon "$1" "$2" 2>/dev/null; }

# picker: prints chosen path(s), one per line. $1 = files | dir
pick() {
  if command -v zenity >/dev/null; then
    if [ "$1" = dir ]; then zenity --file-selection --directory --title="Wallpaper folder" 2>/dev/null
    else zenity --file-selection --multiple --separator=$'\n' --title="Add wallpapers" \
           --file-filter='Images | *.jpg *.jpeg *.png *.webp *.JPG *.JPEG *.PNG *.WEBP' 2>/dev/null; fi
  elif command -v kdialog >/dev/null; then
    if [ "$1" = dir ]; then kdialog --getexistingdirectory "$HOME/Pictures" 2>/dev/null
    else kdialog --multiple --separate-output --getopenfilename "$HOME/Pictures" 'image/jpeg image/png image/webp' 2>/dev/null; fi
  elif command -v yad >/dev/null; then
    if [ "$1" = dir ]; then yad --file --directory 2>/dev/null
    else yad --file --multiple --separator=$'\n' 2>/dev/null; fi
  else
    return 127
  fi
}

case "$1" in
  dir) echo "$dir" ;;
  list)
    now=""; [ -f "$cur" ] && now=$(sed -n 2p "$cur")
    printf '{"dir":"%s","current":"%s","files":[' "$(json "$dir")" "$(json "$now")"
    first=1
    while IFS= read -r f; do
      [ $first = 1 ] || printf ','; first=0
      printf '{"path":"%s","name":"%s"}' "$(json "$f")" "$(json "$(basename "$f")")"
    done < <(find "$dir" -maxdepth 2 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | sort | head -n 300)
    printf ']}\n'
    ;;
  open)
    exec bash "$(dirname "$0")/apps.sh" run files "$dir"
    ;;
  add)
    files=$(pick files); rc=$?
    if [ $rc = 127 ]; then
      note "Add wallpapers" "No file picker installed (zenity / kdialog). Opening the folder: copy images into $dir"
      exec bash "$(dirname "$0")/apps.sh" run files "$dir"
    fi
    n=0
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      cp -n -- "$f" "$dir/" && n=$((n + 1))
    done <<< "$files"
    [ $n -gt 0 ] && note "Wallpapers added" "$n image(s) copied to $dir"
    ;;
  choose-dir)
    d=$(pick dir); rc=$?
    if [ $rc = 127 ]; then
      note "Wallpaper folder" "No folder picker installed (zenity / kdialog). Put the path in $dirf"
      exit 1
    fi
    [ -n "$d" ] && [ -d "$d" ] && printf '%s\n' "$d" > "$dirf"
    ;;
  reset-dir) rm -f "$dirf" ;;
  *) echo "usage: wallpapers.sh dir | list | open | add | choose-dir | reset-dir" >&2; exit 2 ;;
esac
