#!/usr/bin/env bash
# The live wallpapers you can pick (Settings > Wallpaper > Live wallpaper; LiveVideo.qml plays them):
#   live-wallpapers.sh list     one JSON array: [{"path", "name", "thumb"}] of the videos / GIFs in ~/Pictures/Wallpapers/live and
#                               ~/Pictures/Live, newest first (a file without a video extension counts when it is one inside). Each gets a thumbnail in ~/.cache/island/live-thumbs/<md5 of the path>.jpg
#                               (a frame 1 s in, by ffmpeg; the first frame of a GIF, by ImageMagick), made once. The island also takes
#                               the colours from that thumbnail, so a live wallpaper colours the desktop like a picture does.
#   live-wallpapers.sh dirs     the folders it reads, one per line (the first is made if neither exists, for "Open folder")
set -uo pipefail
dirs=("$HOME/Pictures/Wallpapers/live" "$HOME/Pictures/Live")
thumbs="$HOME/.cache/island/live-thumbs"

case "${1:-list}" in
  dirs)
    [ -d "${dirs[0]}" ] || [ -d "${dirs[1]}" ] || mkdir -p "${dirs[0]}"
    for d in "${dirs[@]}"; do [ -d "$d" ] && echo "$d"; done
    exit 0 ;;
  list) ;;
  *) echo "usage: live-wallpapers.sh list | dirs" >&2; exit 2 ;;
esac

mkdir -p "$thumbs"
json() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; printf '"%s"' "$s"; }
# the videos / GIFs among the files: by extension, and a file without one of those (a download saved as just "home") by what is in
# it (file --mime-type: video/* or image/gif), all in one `file` call
is_media() {
  local f rest=()
  while IFS= read -r f; do
    case "${f,,}" in
      *.mp4|*.webm|*.mkv|*.mov|*.gif) printf '%s\n' "$f" ;;
      *.jpg|*.jpeg|*.png|*.webp|*.txt|*.json|*.md) ;;
      *) rest+=("$f") ;;
    esac
  done
  [ ${#rest[@]} -gt 0 ] && command -v file >/dev/null || return 0
  file -N -0 --mime-type -- "${rest[@]}" 2>/dev/null | while IFS= read -r -d '' f && IFS= read -r m; do
    case "${m#*: }" in video/*|image/gif) printf '%s\n' "$f" ;; esac
  done
}
first=1
printf '['
while IFS= read -r f; do
  [ -n "$f" ] || continue
  t="$thumbs/$(printf '%s' "$f" | md5sum | cut -d' ' -f1).jpg"
  if [ ! -s "$t" ]; then
    case "${f,,}" in
      *.gif) { command -v magick >/dev/null && magick "${f}[0]" -resize 480x300^ -gravity center -extent 480x300 "$t"; } >/dev/null 2>&1 ;;
      *)     { command -v ffmpeg >/dev/null && ffmpeg -loglevel error -y -ss 1 -i "$f" -frames:v 1 -vf "scale=480:300:force_original_aspect_ratio=increase,crop=480:300" "$t" </dev/null \
                 || ffmpeg -loglevel error -y -i "$f" -frames:v 1 -vf "scale=480:300:force_original_aspect_ratio=increase,crop=480:300" "$t" </dev/null; } >/dev/null 2>&1 ;;
    esac
  fi
  [ -s "$t" ] || t=""
  name=$(basename "$f"); name=${name%.*}
  [ $first -eq 1 ] || printf ','
  first=0
  printf '{"path":%s,"name":%s,"thumb":%s}' "$(json "$f")" "$(json "$name")" "$(json "$t")"
done < <(for d in "${dirs[@]}"; do
           [ -d "$d" ] && find "$d" -maxdepth 1 -type f -printf '%T@\t%p\n'
         done 2>/dev/null | sort -rn | cut -f2- | is_media)
printf ']\n'
