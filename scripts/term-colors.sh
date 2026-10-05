#!/usr/bin/env bash
# Terminal colours from the wallpaper. Reads the island's palette (~/.cache/island/palette.json, made by `hx palette`)
# and
#   1. writes a colour file for each terminal you have:  foot, kitty, alacritty, wezterm, ghostty, konsole-less terminals
#      keep working through (2)
#   2. repaints every terminal that is open right now (OSC colour codes sent to each pty), so they change live
# New terminals read the files, so they start in the same colours. Run by the island on every wallpaper change,
# and by hand:  ~/.config/Halcyon/scripts/term-colors.sh
pal="$HOME/.cache/island/palette.json"
[ -f "$pal" ] || exit 0
get() { sed -n "s/.*\"$1\": *\"\\(#[0-9a-fA-F]\\{6\\}\\)\".*/\\1/p" "$pal" | head -n1; }
bg=$(get bg); surface=$(get surface); surfaceHi=$(get surfaceHi); accent=$(get accent); accent2=$(get accent2); fg=$(get text); muted=$(get muted)
[ -n "$bg" ] && [ -n "$fg" ] && [ -n "$accent" ] || exit 0

# hex helpers: mix two colours, lighten
rgb() { printf '%d %d %d' "0x${1:1:2}" "0x${1:3:2}" "0x${1:5:2}"; }
mix() { # mix A B percent-of-B
  read -r r1 g1 b1 <<<"$(rgb "$1")"; read -r r2 g2 b2 <<<"$(rgb "$2")"; p=$3
  printf '#%02x%02x%02x' $(( (r1*(100-p) + r2*p)/100 )) $(( (g1*(100-p) + g2*p)/100 )) $(( (b1*(100-p) + b2*p)/100 ))
}
# the 8 ANSI hues. Red still looks like red and green like green, but every colour is pulled hard toward the wallpaper:
# blue and magenta ARE the wallpaper's two accents (barely changed), the others take 40% of the accent so each wallpaper
# gives a clearly different terminal, not just a slightly different background.
tint() { mix "$1" "$accent" 40; }
black=$surface;           bblack=$muted
red=$(mix "#e57a85" "$accent" 30); bred=$(mix "$red" "#ffffff" 18)
green=$(tint "#8fd19e");  bgreen=$(mix "$green" "#ffffff" 18)
yellow=$(tint "#e5c07b"); byellow=$(mix "$yellow" "#ffffff" 18)
blue=$(mix "#6fa8e8" "$accent" 80);      bblue=$(mix "$blue" "#ffffff" 18)
magenta=$(mix "#c792ea" "$accent2" 80);  bmagenta=$(mix "$magenta" "#ffffff" 18)
cyan=$(mix "#7fd6d6" "$accent2" 40);     bcyan=$(mix "$cyan" "#ffffff" 18)
white=$(mix "$fg" "$bg" 18); bwhite=$fg

colors=("$black" "$red" "$green" "$yellow" "$blue" "$magenta" "$cyan" "$white" "$bblack" "$bred" "$bgreen" "$byellow" "$bblue" "$bmagenta" "$bcyan" "$bwhite")
nohash() { echo "${1#\#}"; }

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
