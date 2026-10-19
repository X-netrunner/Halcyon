#!/usr/bin/env bash
# Prints the wallpaper to show.
#   wallpaper.sh          -> the wallpaper chosen for this boot (picks one on the first call after boot)
#   wallpaper.sh next     -> force a new random one (and remember it for the rest of this boot)
#   wallpaper.sh set <f>  -> use this file (and remember it for the rest of this boot)
#   wallpaper.sh keep     -> copy the current online wallpaper into the wallpaper folder
# Source (Settings > Wallpaper > Source): local = your folder, online = Wallhaven by category, mixed = either, 50/50.
# Online pictures are cached in ~/.cache/island/online-wp (newest 60 kept); with no network `next` falls back to the folder.
# The folder is ~/Pictures/Wallpapers unless Settings > Wallpaper > Change folder picked another one
# (saved in ~/.local/state/island/wallpaper.dir, see scripts/wallpapers.sh).
dir="$HOME/Pictures/Wallpapers"
[ -s "$HOME/.local/state/island/wallpaper.dir" ] && dir=$(head -n1 "$HOME/.local/state/island/wallpaper.dir")
state="$HOME/.local/state/island/wallpaper"
sdir="$HOME/.local/state/island"
src=local; [ -s "$sdir/wallpaper-source" ] && src=$(head -n1 "$sdir/wallpaper-source")
cat=nature; [ -s "$sdir/wallpaper-cat" ] && cat=$(head -n1 "$sdir/wallpaper-cat")
cache="$HOME/.cache/island/online-wp"
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
mkdir -p "$(dirname "$state")"

# When the picture really changes the time is kept in wallpaper-changed (one epoch number, read by scripts/timeline.py for the
# Settings timeline). The same picture picked again is not a change, and a failed write never matters here.
prev=""; [ -f "$state" ] && prev=$(sed -n 2p "$state")
stampf="$(dirname "$state")/wallpaper-changed"
mark() {
  [ "$1" = "$prev" ] && return 0
  { printf '%(%s)T\n' -1 > "$stampf.tmp" && mv -f "$stampf.tmp" "$stampf"; } 2>/dev/null
  return 0
}

if [ "$1" = "keep" ]; then
  cur=$(sed -n 2p "$state"); case "$cur" in "$cache"/*) mkdir -p "$dir"; cp -n -- "$cur" "$dir/" && echo "$dir/$(basename "$cur")" ;; esac
  exit 0
fi

if [ "$1" = "set" ]; then
  [ -f "$2" ] || exit 1
  printf '%s\n%s\n' "$boot" "$2" > "$state"
  mark "$2"
  echo "$2"; exit 0
fi

saved_boot=""; saved=""
if [ -f "$state" ]; then
  saved_boot=$(sed -n 1p "$state"); saved=$(sed -n 2p "$state")
fi

if [ "$1" != "next" ] && [ "$saved_boot" = "$boot" ] && [ -f "$saved" ]; then
  echo "$saved"; exit 0
fi


# ---- online: one random picture of the chosen category from Wallhaven (SFW only, no API key needed)
fetch_online() {
  command -v curl >/dev/null || return 1
  local c="$cat" q="" k="100" api list url f
  if [ "$c" = random ]; then c=$(printf '%s\n' nature movies anime anime-art space city minimal cars | shuf -n 1); fi
  case "$c" in
    nature)    q="nature";                k=100 ;;
    movies)    q="movies";                k=100 ;;
    anime)     q="";                      k=010 ;;   # characters and general anime wallpapers
    anime-art) q="scenery";               k=010 ;;   # anime-style landscapes and scenery
    space)     q="space";                 k=100 ;;
    city)      q="city night";            k=100 ;;
    minimal)   q="minimal";               k=100 ;;
    cars)      q="cars";                  k=100 ;;
    *)         q="$c";                    k=111 ;;   # anything else is used as a search word
  esac
  api="https://wallhaven.cc/api/v1/search?categories=$k&purity=100&sorting=random&atleast=1920x1080&ratios=16x9,16x10"
  [ -n "$q" ] && api="$api&q=$(printf '%s' "$q" | sed 's/ /+/g')"
  list=$(curl -fsSL --max-time 15 "$api" 2>/dev/null | grep -o '"path":"[^"]*"' | sed -e 's/^"path":"//' -e 's/"$//' -e 's#\\/#/#g') || return 1
  [ -n "$list" ] || return 1
  url=$(printf '%s\n' "$list" | grep -vF "$(basename "${saved:-none}")" | shuf -n 1)
  [ -n "$url" ] || return 1
  mkdir -p "$cache/$c"
  f="$cache/$c/$(basename "$url")"
  if [ ! -s "$f" ]; then curl -fsSL --max-time 60 -o "$f.part" "$url" 2>/dev/null && mv -f "$f.part" "$f"; fi
  [ -s "$f" ] || return 1
  ls -t "$cache"/*/* 2>/dev/null | tail -n +61 | xargs -r rm -f --   # keep the newest 60
  echo "$f"
}

pick() {
  find "$dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | shuf -n 1
}
p=""
if [ "$1" = "next" ]; then
  if [ "$src" = online ] || { [ "$src" = mixed ] && [ $((RANDOM % 2)) = 0 ]; }; then
    p=$(fetch_online) || p=""
    [ -n "$p" ] || notify-send -a Halcyon "Online wallpaper" "No network or no result: using your folder" 2>/dev/null
  fi
elif [ "$src" != local ]; then          # boot pick: a cached online picture (no network needed at login), else the folder
  p=$(find "$cache" -type f 2>/dev/null | shuf -n 1)
fi
[ -n "$p" ] || p=$(pick)
if [ "$1" = "next" ] && [ "$src" = local ]; then            # try not to repeat the current one
  for _ in 1 2 3 4 5; do [ "$p" != "$saved" ] && break; p=$(pick); done
fi
[ -n "$p" ] || exit 0
printf '%s\n%s\n' "$boot" "$p" > "$state"
mark "$p"
echo "$p"
