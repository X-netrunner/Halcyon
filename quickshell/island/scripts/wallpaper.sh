#!/usr/bin/env bash
# Prints the wallpaper to show.
#   wallpaper.sh          -> the wallpaper chosen for this boot (picks one on the first call after boot)
#   wallpaper.sh next     -> force a new random one (and remember it for the rest of this boot)
#   wallpaper.sh set <f>  -> use this file (and remember it for the rest of this boot)
# The folder is ~/Pictures/Wallpapers unless Settings > Wallpaper > Change folder picked another one
# (saved in ~/.local/state/island/wallpaper.dir, see scripts/wallpapers.sh).
dir="$HOME/Pictures/Wallpapers"
[ -s "$HOME/.local/state/island/wallpaper.dir" ] && dir=$(head -n1 "$HOME/.local/state/island/wallpaper.dir")
state="$HOME/.local/state/island/wallpaper"
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
mkdir -p "$(dirname "$state")"

if [ "$1" = "set" ]; then
  [ -f "$2" ] || exit 1
  printf '%s\n%s\n' "$boot" "$2" > "$state"
  echo "$2"; exit 0
fi

saved_boot=""; saved=""
if [ -f "$state" ]; then
  saved_boot=$(sed -n 1p "$state"); saved=$(sed -n 2p "$state")
fi

if [ "$1" != "next" ] && [ "$saved_boot" = "$boot" ] && [ -f "$saved" ]; then
  echo "$saved"; exit 0
fi

pick() {
  find "$dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | shuf -n 1
}
p=$(pick)
if [ "$1" = "next" ]; then            # try not to repeat the current one
  for _ in 1 2 3 4 5; do [ "$p" != "$saved" ] && break; p=$(pick); done
fi
[ -n "$p" ] || exit 0
printf '%s\n%s\n' "$boot" "$p" > "$state"
echo "$p"
