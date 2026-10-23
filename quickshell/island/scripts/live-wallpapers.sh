#!/usr/bin/env bash
# The live wallpapers you can pick (Settings > Wallpaper > Live wallpaper; LiveVideo.qml plays them):
#   live-wallpapers.sh list     one JSON array: [{"path", "name", "thumb"}] of the videos / GIFs in ~/Pictures/Wallpapers/live and
#                               ~/Pictures/Live, newest first (a file without a video extension counts when it is one inside). Each gets a thumbnail in ~/.cache/island/live-thumbs/<md5 of the path>.jpg
#                               (a frame 1 s in, by ffmpeg; the first frame of a GIF, by ImageMagick), made once. The island also takes
#                               the colours from that thumbnail, so a live wallpaper colours the desktop like a picture does.
#   live-wallpapers.sh dirs     the folders it reads, one per line (the first is made if neither exists, for "Open folder")
#   live-wallpapers.sh proxies  make the screen-sized copies now (list starts this in the background by itself)
# A video much bigger than your screen (a 4K file on a 1920x1200 panel) is decoded at full size every frame for nothing: `list` makes
# a copy at the screen's size once, in the background at the lowest priority, in ~/.cache/island/live-proxy/<md5 of the path>.mp4
# (LiveVideo.qml plays that copy when it is there, the original otherwise). Silent, no sound track, about a tenth of the work to play.
set -uo pipefail
dirs=("$HOME/Pictures/Wallpapers/live" "$HOME/Pictures/Live")
thumbs="$HOME/.cache/island/live-thumbs"
proxies="$HOME/.cache/island/live-proxy"

# the biggest screen, in real pixels ("1920 1200"); nothing without Hyprland
screen_px() { command -v hyprctl >/dev/null && command -v jq >/dev/null && hyprctl -j monitors 2>/dev/null | jq -r 'max_by(.width * .height) | "\(.width) \(.height)"' 2>/dev/null; }
make_proxies() {
  command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || return 0
  local sw sh f p w h
  read -r sw sh < <(screen_px) || return 0
  [[ "$sw" =~ ^[0-9]+$ && "$sh" =~ ^[0-9]+$ ]] || return 0
  mkdir -p "$proxies"
  while IFS= read -r f; do
    case "${f,,}" in *.gif) continue ;; esac
    p="$proxies/$(printf '%s' "$f" | md5sum | cut -d' ' -f1).mp4"
    [ -s "$p" ] && [ "$p" -nt "$f" ] && continue
    IFS=x read -r w h < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$f" </dev/null 2>/dev/null)
    [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || continue
    # only when it is clearly bigger than the screen in both directions (a 1440p file on a 1200p panel is left alone)
    [ $((w * 4)) -gt $((sw * 5)) ] && [ $((h * 4)) -gt $((sh * 5)) ] || continue
    # scaled to COVER the screen (the player crops, like the original), even sizes, constant quality, no audio
    nice -n 19 ionice -c 3 ffmpeg -loglevel error -y -i "$f" -an -sn -dn \
      -vf "scale=w='if(gt(iw/ih,$sw/$sh),-2,$sw)':h='if(gt(iw/ih,$sw/$sh),$sh,-2)'" \
      -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -movflags +faststart -f mp4 "$p.part" </dev/null >/dev/null 2>&1 \
      && mv -f "$p.part" "$p" || rm -f "$p.part"
  done
}

case "${1:-list}" in
  dirs)
    [ -d "${dirs[0]}" ] || [ -d "${dirs[1]}" ] || mkdir -p "${dirs[0]}"
    for d in "${dirs[@]}"; do [ -d "$d" ] && echo "$d"; done
    exit 0 ;;
  list|proxies) ;;
  *) echo "usage: live-wallpapers.sh list | dirs | proxies" >&2; exit 2 ;;
esac

mkdir -p "$thumbs" "$(dirname "$proxies")"
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
media_files() {      # newest first
  for d in "${dirs[@]}"; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -type f -printf '%T@\t%p\n'
  done 2>/dev/null | sort -rn | cut -f2- | is_media
}
if [ "${1:-list}" = proxies ]; then media_files | make_proxies; exit 0; fi
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
done < <(media_files)
printf ']\n'
# the screen-sized copies, after the answer (one maker at a time; it never holds up the list)
( command -v flock >/dev/null && { flock -n 9 || exit 0; }; media_files | make_proxies ) </dev/null >/dev/null 2>&1 9>"$proxies.lock" &
disown 2>/dev/null
