#!/usr/bin/env bash
# Prints the wallpaper to show.
#   wallpaper.sh          -> the wallpaper chosen for this boot (picks one on the first call after boot)
#   wallpaper.sh next     -> force a new random one (and remember it for the rest of this boot)
#   wallpaper.sh set <f>  -> use this file (and remember it for the rest of this boot)
#   wallpaper.sh back     -> the previous wallpaper (the last 30 are remembered)
#   wallpaper.sh keep     -> copy the current online wallpaper into the wallpaper folder
# Source (Settings > Wallpaper > Source): local = your folder, online = Wallhaven by category, mixed = either, 50/50.
# With Online / Mixed the NEXT online picture is downloaded in the background right after each change, so "next" is instant.
# With Local nothing is ever preloaded (and a leftover preload is deleted).
# Online pictures are cached in ~/.cache/island/online-wp (newest 60 kept); with no network `next` falls back to the folder.
# The folder is ~/Pictures/Wallpapers unless Settings > Wallpaper > Change folder picked another one
# (saved in ~/.local/state/island/wallpaper.dir, see scripts/wallpapers.sh).
dir="$HOME/Pictures/Wallpapers"
[ -s "$HOME/.local/state/island/wallpaper.dir" ] && dir=$(head -n1 "$HOME/.local/state/island/wallpaper.dir")
state="$HOME/.local/state/island/wallpaper"
sdir="$HOME/.local/state/island"
src=local; [ -s "$sdir/wallpaper-source" ] && src=$(head -n1 "$sdir/wallpaper-source")
cat=nature; [ -s "$sdir/wallpaper-cat" ] && cat=$(head -n1 "$sdir/wallpaper-cat")
query=""; [ -s "$sdir/wallpaper-query" ] && query=$(head -n1 "$sdir/wallpaper-query")
cache="$HOME/.cache/island/online-wp"
history="$sdir/wallpaper-history"; preloadf="$sdir/wallpaper-preload"
key="$cat:$query"
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

# the last 30 wallpapers, newest last (for `back`)
push_hist() {
  [ -n "$1" ] && [ -f "$1" ] && [ "$1" != "$2" ] || return 0
  { echo "$1" >> "$history" && tail -n 30 "$history" > "$history.tmp" && mv -f "$history.tmp" "$history"; } 2>/dev/null
  return 0
}

if [ "$1" = "keep" ]; then
  cur=$(sed -n 2p "$state")
  case "$cur" in
    "$cache"/*) mkdir -p "$dir"; cp -n -- "$cur" "$dir/" 2>/dev/null; notify-send -a Halcyon "Wallpaper kept" "Saved to $(basename "$dir")/$(basename "$cur")" 2>/dev/null; echo "$dir/$(basename "$cur")" ;;
    *) notify-send -a Halcyon "Wallpaper" "This one is already one of your own files" 2>/dev/null ;;
  esac
  exit 0
fi

if [ "$1" = "back" ]; then
  while [ -s "$history" ]; do
    last=$(tail -n1 "$history"); sed -i '$d' "$history" 2>/dev/null
    if [ -f "$last" ] && [ "$last" != "$prev" ]; then
      printf '%s\n%s\n' "$boot" "$last" > "$state"; mark "$last"; echo "$last"; exit 0
    fi
  done
  [ -f "$prev" ] && echo "$prev"
  exit 0
fi

if [ "$1" = "set" ]; then
  [ -f "$2" ] || exit 1
  push_hist "$prev" "$2"
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
  local c="$cat" q="" k="100" list url f
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
    custom)    q="${query:-nature}"; k=111; c="custom" ;;   # the search word typed in Settings
    *)         q="$c";                    k=111 ;;   # anything else is used as a search word
  esac
  local qarg=()
  [ -n "$q" ] && qarg=(--data-urlencode "q=$q")
  list=$(curl -fsSL --max-time 15 -G "https://wallhaven.cc/api/v1/search" --data "categories=$k" --data "purity=100" --data "sorting=random" \
           --data "atleast=1920x1080" --data "ratios=16x9,16x10" "${qarg[@]}" 2>/dev/null | grep -o '"path":"[^"]*"' | sed -e 's/^"path":"//' -e 's/"$//' -e 's#\\/#/#g') || return 1
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

# the next online picture, downloaded in the background (never when the source is Local)
use_preload() {
  [ -s "$preloadf" ] || return 1
  local k f; IFS=$'\t' read -r k f < "$preloadf"
  rm -f "$preloadf"
  [ "$k" = "$key" ] && [ -s "$f" ] && echo "$f"
}
start_preload() {
  if [ "$src" = local ]; then rm -f "$preloadf" 2>/dev/null; return 0; fi
  command -v curl >/dev/null || return 0
  [ -s "$preloadf" ] && return 0
  (
    command -v flock >/dev/null && { flock -n 9 || exit 0; }
    p2=$(fetch_online) && printf '%s\t%s\n' "$key" "$p2" > "$preloadf"
  ) </dev/null >/dev/null 2>&1 9>"$sdir/.preload.lock" &
  disown 2>/dev/null
  return 0
}

pick() {
  find "$dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | shuf -n 1
}
p=""
if [ "$1" = "next" ]; then
  if [ "$src" = online ] || { [ "$src" = mixed ] && [ $((RANDOM % 2)) = 0 ]; }; then
    p=$(use_preload) || p=$(fetch_online) || p=""
    [ -n "$p" ] || notify-send -a Halcyon "Online wallpaper" "No network or no result: using your folder" 2>/dev/null
  fi
elif [ "$src" != local ]; then          # boot pick: a cached online picture (no network needed at login), else the folder
  p=$(find "$cache" -type f -name 'wallhaven-*' ! -name '*.part' 2>/dev/null | shuf -n 1)
fi
[ -n "$p" ] || p=$(pick)
if [ "$1" = "next" ] && [ "$src" = local ]; then            # try not to repeat the current one
  for _ in 1 2 3 4 5; do [ "$p" != "$saved" ] && break; p=$(pick); done
fi
[ -n "$p" ] || exit 0
push_hist "$saved" "$p"
printf '%s\n%s\n' "$boot" "$p" > "$state"
mark "$p"
start_preload
echo "$p"
