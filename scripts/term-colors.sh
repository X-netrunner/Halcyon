#!/usr/bin/env bash
# Terminal colours from the wallpaper. Reads the island's palette (~/.cache/island/palette.json, made by `hx palette`)
# and
#   1. writes a colour file for each terminal you have:  foot, kitty, alacritty, wezterm, ghostty, konsole-less terminals
#      keep working through (2)
#   2. repaints every terminal that is open right now (OSC colour codes sent to each pty), so they change live
# New terminals read the files, so they start in the same colours. Run by the island on every wallpaper change,
# and by hand:  ~/.config/Halcyon/scripts/term-colors.sh
pal="$HOME/.cache/island/palette.json"
# Usage:  term-colors.sh                 automatic run (does nothing when Settings > Colours > "Terminals follow the wallpaper" is off)
#         term-colors.sh --now           run anyway
#         term-colors.sh --drift A B     the island is cycling its accent through the wallpaper: A / B are the accent colours right now
#                                        (cursor, blue and magenta follow them; the rest keeps the wallpaper's colours)
now=0; drift=0; d1=""; d2=""; exp_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --now) now=1 ;;
    --export) exp_only=1; now=1 ;;     # only write ~/.cache/island/ansi.env (used by app-themes.sh), touch no terminal
    --drift) drift=1; d1="${2:-}"; d2="${3:-}"; shift 2 ;;
  esac
  shift
done
[ -f "$pal" ] || exit 0
# GTK apps (Thunar ...) and the app themes (Starship, btop, yazi, Spotify, Discord) follow the same palette
# (scripts/gtk-theme.sh, scripts/app-themes.sh); not on every accent-drift tick
if [ "$drift" = 0 ] && [ "$exp_only" = 0 ]; then
  echo "$(date +%T) term-colors: starting the app themes" >> "$HOME/.cache/island/app-themes.log"
  bash "$(dirname "$0")/gtk-theme.sh" --auto >/dev/null 2>&1 &
  bash "$(dirname "$0")/app-themes.sh" --auto >/dev/null 2>&1 &
fi
state="$HOME/.local/state/island"
# Settings > Colours > "Terminals follow the wallpaper": off = automatic runs do nothing (`--now` still forces it)
if [ "$now" = 0 ] && [ "$(head -n1 "$state/term-follow" 2>/dev/null)" = "off" ]; then exit 0; fi
# Settings > Colours > "Terminal colours": spectrum (every colour of the wallpaper) | accent (one colour, the old look)
mode=$(head -n1 "$state/term-mode" 2>/dev/null); [ "$mode" = accent ] || mode=spectrum
get() { sed -n "s/.*\"$1\": *\"\\(#[0-9a-fA-F]\\{6\\}\\)\".*/\\1/p" "$pal" | head -n1; }
bg=$(get bg); surface=$(get surface); surfaceHi=$(get surfaceHi); accent=$(get accent); accent2=$(get accent2); fg=$(get text); muted=$(get muted)
[ -n "$bg" ] && [ -n "$fg" ] && [ -n "$accent" ] || exit 0
if [ "$drift" = 1 ]; then
  case "$d1" in \#??????) accent="$d1" ;; esac
  case "$d2" in \#??????) accent2="$d2" ;; esac
fi
# every colour the wallpaper has (palette.sh "swatches"), strongest first
SW=(); sw=$(sed -n 's/.*"swatches": *\[\([^]]*\)\].*/\1/p' "$pal" | head -n1 | tr -d '" ')
[ -n "$sw" ] && IFS=, read -ra SW <<<"$sw"

# colour helpers (no subshells: this runs every few seconds while the accent cycles)
mixv() {   # mixv A B percent-of-B  ->  $MIX
  local a=${1#\#} b=${2#\#} p=$3
  printf -v MIX '#%02x%02x%02x' \
    $(( (16#${a:0:2} * (100 - p) + 16#${b:0:2} * p) / 100 )) \
    $(( (16#${a:2:2} * (100 - p) + 16#${b:2:2} * p) / 100 )) \
    $(( (16#${a:4:2} * (100 - p) + 16#${b:4:2} * p) / 100 ))
}
hue_of() {   # hue_of #rrggbb  ->  $H  (0..359)
  local c=${1#\#} r g b mx mn d
  r=$((16#${c:0:2})); g=$((16#${c:2:2})); b=$((16#${c:4:2}))
  mx=$r; mn=$r
  (( g > mx )) && mx=$g; (( b > mx )) && mx=$b
  (( g < mn )) && mn=$g; (( b < mn )) && mn=$b
  d=$(( mx - mn ))
  if (( d == 0 )); then H=0; return; fi
  if   (( mx == r )); then H=$(( (60 * (g - b) / d + 360) % 360 ))
  elif (( mx == g )); then H=$(( 60 * (b - r) / d + 120 ))
  else                     H=$(( 60 * (r - g) / d + 240 )); fi
  (( H < 0 )) && H=$(( H + 360 ))
  H=$(( H % 360 ))
}
SH=(); for c in "${SW[@]}"; do hue_of "$c"; SH+=("$H"); done
# Each wallpaper colour goes to the ANSI slot whose hue is closest to it (within ~50 degrees), and a slot only takes one
# colour, so green / blue / cyan never end up as the same teal. A slot the wallpaper has no colour for keeps its stock
# colour, only nudged a little towards the accent so it still belongs.
SLOTH=(355 140 45 215 290 185)         # red green yellow blue magenta cyan
CLAIM=(-1 -1 -1 -1 -1 -1); CDIST=(999 999 999 999 999 999)
for i in "${!SH[@]}"; do
  bj=-1; bd=999
  for j in 0 1 2 3 4 5; do
    d=$(( (SH[i] - SLOTH[j] + 540) % 360 - 180 )); (( d < 0 )) && d=$(( -d ))
    (( d < bd )) && { bd=$d; bj=$j; }
  done
  if (( bj >= 0 && bd <= 50 && bd < CDIST[bj] )); then CLAIM[bj]=$i; CDIST[bj]=$bd; fi
done
slot() {   # slot STOCK-COLOUR SLOT-INDEX  ->  $SLOT
  if (( CLAIM[$2] >= 0 )); then mixv "$1" "${SW[CLAIM[$2]]}" 70; else mixv "$1" "$accent" 15; fi
  SLOT=$MIX
}
brighten() { mixv "$1" "#ffffff" 18; BRIGHT=$MIX; }

black=$surface; bblack=$muted
if [ "$mode" = spectrum ]; then
  # Every ANSI hue is taken from the wallpaper's own colours. A red + purple wallpaper gives a red red and a purple
  # magenta (not a red everything); hues the wallpaper does not have stay close to their usual colour.
  slot "#e57a85" 0; red=$SLOT
  slot "#8fd19e" 1; green=$SLOT
  slot "#e5c07b" 2; yellow=$SLOT
  slot "#6fa8e8" 3; blue=$SLOT
  slot "#c792ea" 4; magenta=$SLOT
  slot "#7fd6d6" 5; cyan=$SLOT
  if [ "$drift" = 1 ]; then mixv "#6fa8e8" "$accent" 75; blue=$MIX; mixv "#c792ea" "$accent2" 75; magenta=$MIX; fi
else
  # the old look: red still looks like red and green like green, but every colour is pulled hard toward the wallpaper's
  # main accent: blue and magenta ARE the wallpaper's two accents (barely changed), the others take 30-40% of the accent
  mixv "#e57a85" "$accent" 30; red=$MIX
  mixv "#8fd19e" "$accent" 40; green=$MIX
  mixv "#e5c07b" "$accent" 40; yellow=$MIX
  mixv "#6fa8e8" "$accent" 80; blue=$MIX
  mixv "#c792ea" "$accent2" 80; magenta=$MIX
  mixv "#7fd6d6" "$accent2" 40; cyan=$MIX
fi
brighten "$red"; bred=$BRIGHT;         brighten "$green"; bgreen=$BRIGHT
brighten "$yellow"; byellow=$BRIGHT;   brighten "$blue"; bblue=$BRIGHT
brighten "$magenta"; bmagenta=$BRIGHT; brighten "$cyan"; bcyan=$BRIGHT
mixv "$fg" "$bg" 18; white=$MIX; bwhite=$fg

colors=("$black" "$red" "$green" "$yellow" "$blue" "$magenta" "$cyan" "$white" "$bblack" "$bred" "$bgreen" "$byellow" "$bblue" "$bmagenta" "$bcyan" "$bwhite")
nohash() { echo "${1#\#}"; }

# the colours every themed app reads (scripts/app-themes.sh): the island palette + the 16 terminal colours
if [ "$drift" = 0 ]; then
  mkdir -p "$HOME/.cache/island"
  {
    echo "A_BG=$bg"; echo "A_FG=$fg"; echo "A_SURF=$surface"; echo "A_HI=$surfaceHi"; echo "A_MUTED=$muted"; echo "A_ACC=$accent"; echo "A_ACC2=$accent2"
    for i in $(seq 0 15); do echo "A_C$i=${colors[$i]}"; done
  } > "$HOME/.cache/island/ansi.env.tmp" && mv "$HOME/.cache/island/ansi.env.tmp" "$HOME/.cache/island/ansi.env"
fi
[ "$exp_only" = 1 ] && exit 0

# ---- 1. colour files (each terminal's main config includes its file; install.sh adds the include once)
mkdir -p "$HOME/.config/foot" "$HOME/.config/kitty" "$HOME/.config/alacritty" "$HOME/.config/ghostty" "$HOME/.config/wezterm"
# foot >= 1.24 renamed [colors] to [colors-dark] (and newer builds reject [colors]); older foot only knows [colors]
foot_sec="colors"
if command -v foot >/dev/null 2>&1; then
  fv=$(foot --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -n1)
  fmaj=${fv%%.*}; fmin=${fv##*.}
  if [ -n "$fv" ] && { [ "${fmaj:-0}" -gt 1 ] || { [ "${fmaj:-0}" -eq 1 ] && [ "${fmin:-0}" -ge 24 ]; }; }; then foot_sec="colors-dark"; fi
fi
{
  echo "[$foot_sec]"
  echo "background=$(nohash "$bg")"; echo "foreground=$(nohash "$fg")"
  echo "selection-background=$(nohash "$surfaceHi")"; echo "selection-foreground=$(nohash "$fg")"
  for i in 0 1 2 3 4 5 6 7; do echo "regular$i=$(nohash "${colors[$i]}")"; done
  for i in 0 1 2 3 4 5 6 7; do echo "bright$i=$(nohash "${colors[$((i+8))]}")"; done
} > "$HOME/.config/foot/halcyon-colors.ini"

{
  echo "background $bg"; echo "foreground $fg"; echo "cursor $accent"; echo "cursor_text_color $bg"
  echo "selection_background $surfaceHi"; echo "selection_foreground $fg"
  echo "url_color $accent2"; echo "active_border_color $accent"; echo "inactive_border_color $muted"
  for i in $(seq 0 15); do echo "color$i ${colors[$i]}"; done
} > "$HOME/.config/kitty/halcyon-colors.conf"

{
  echo "[colors.primary]"; echo "background = \"$bg\""; echo "foreground = \"$fg\""
  echo "[colors.cursor]"; echo "cursor = \"$accent\""; echo "text = \"$bg\""
  echo "[colors.selection]"; echo "background = \"$surfaceHi\""; echo "text = \"$fg\""
  echo "[colors.normal]"
  n=(black red green yellow blue magenta cyan white)
  for i in 0 1 2 3 4 5 6 7; do echo "${n[$i]} = \"${colors[$i]}\""; done
  echo "[colors.bright]"
  for i in 0 1 2 3 4 5 6 7; do echo "${n[$i]} = \"${colors[$((i+8))]}\""; done
} > "$HOME/.config/alacritty/halcyon-colors.toml"

{
  echo "background = $bg"; echo "foreground = $fg"; echo "cursor-color = $accent"
  echo "selection-background = $surfaceHi"; echo "selection-foreground = $fg"
  for i in $(seq 0 15); do echo "palette = $i=${colors[$i]}"; done
} > "$HOME/.config/ghostty/halcyon-colors"

{
  echo "return {"
  echo "  foreground = '$fg', background = '$bg', cursor_bg = '$accent', cursor_fg = '$bg', cursor_border = '$accent',"
  echo "  selection_bg = '$surfaceHi', selection_fg = '$fg',"
  printf "  ansi = {"; for i in 0 1 2 3 4 5 6 7; do printf "'%s'," "${colors[$i]}"; done; echo "},"
  printf "  brights = {"; for i in 0 1 2 3 4 5 6 7; do printf "'%s'," "${colors[$((i+8))]}"; done; echo "},"
  echo "}"
} > "$HOME/.config/wezterm/halcyon-colors.lua"

# ---- 2. repaint the terminals that are open now: OSC 10 fg, 11 bg, 12 cursor, 4;n palette entries
seq_osc() {
  printf '\033]10;%s\033\\\033]11;%s\033\\\033]12;%s\033\\' "$fg" "$bg" "$accent"
  for i in $(seq 0 15); do printf '\033]4;%d;%s\033\\' "$i" "${colors[$i]}"; done
}
payload=$(seq_osc)
for t in /dev/pts/[0-9]*; do
  [ -O "$t" ] && [ -w "$t" ] && printf '%s' "$payload" > "$t" 2>/dev/null
done
exit 0
