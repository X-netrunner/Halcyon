#!/usr/bin/env bash
# Wallpaper folder helper (Settings > Wallpaper). The folder is ~/Pictures/Wallpapers unless you pick another one.
#   wallpapers.sh dir            print the folder (made if it does not exist)
#   wallpapers.sh list           JSON: folder, the wallpaper in use, and every image in it
#   wallpapers.sh colors         one line per image: <path><TAB>["#accent","#accent2",...swatches]  (the Wallpaper Gallery's colour circles;
#                                read once per picture with palette.sh and cached in ~/.cache/island/wpcolors)
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

# ---- colours of one picture, cached by path + modification time + colour intensity
cache="$HOME/.cache/island/wpcolors"
boost=1; [ -r "$state/color-boost" ] && read -r boost < "$state/color-boost"
case "$boost" in ''|*[!0-9.]*) boost=1 ;; esac
cache_key() {                    # $1 = path  $2 = mtime
  local k="${1//\//%}.$2.$boost"
  [ ${#k} -gt 200 ] && k=$(printf '%s' "$k" | md5sum | cut -c1-32)
  printf '%s' "$k"
}
color1() {                       # color1 <file>: prints "<file><TAB>[...]", from the cache or read from the picture
  local f="$1" m key arr j acc acc2 sw
  [ -f "$f" ] || return 1
  m=$(stat -c %Y -- "$f" 2>/dev/null) || return 1
  key="$cache/$(cache_key "$f" "$m")"
  if [ ! -s "$key" ]; then
    j=$(bash "$(dirname "$0")/../quickshell/island/scripts/palette.sh" "$f" --print 2>/dev/null) || return 1
    acc=$(printf '%s' "$j" | grep -o '"accent":"#[0-9a-fA-F]*"' | head -n1 | cut -d'"' -f4)
    acc2=$(printf '%s' "$j" | grep -o '"accent2":"#[0-9a-fA-F]*"' | head -n1 | cut -d'"' -f4)
    sw=$(printf '%s' "$j" | grep -o '"swatches":\[[^]]*\]' | head -n1)
    sw=${sw#*:\[}; sw=${sw%\]}
    [ -n "$acc" ] || return 1
    arr="[\"$acc\""
    [ -n "$acc2" ] && arr="$arr,\"$acc2\""
    [ -n "$sw" ] && arr="$arr,$sw"
    arr="$arr]"
    mkdir -p "$cache"
    printf '%s\n' "$arr" > "$key.tmp.$$" && mv -f "$key.tmp.$$" "$key"
  fi
  printf '%s\t%s\n' "$f" "$(<"$key")"
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
  color1) color1 "$2" ;;
  colors)
    # pictures that are already cached are printed at once, the others are read 3 at a time and printed as they finish
    todo=$(mktemp) || exit 1
    trap 'rm -f "$todo"' EXIT
    while IFS=$'\t' read -r f m; do
      key="$cache/$(cache_key "$f" "${m%%.*}")"
      if [ -s "$key" ]; then printf '%s\t%s\n' "$f" "$(<"$key")"; else printf '%s\0' "$f" >> "$todo"; fi
    done < <(find "$dir" -maxdepth 2 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -printf '%p\t%T@\n' 2>/dev/null | sort | head -n 300)
    [ -s "$todo" ] && xargs -0 -P 3 -n 1 bash "$0" color1 < "$todo"
    find "$cache" -type f -mtime +60 -delete 2>/dev/null
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
  *) echo "usage: wallpapers.sh dir | list | colors | open | add | choose-dir | reset-dir" >&2; exit 2 ;;
esac
