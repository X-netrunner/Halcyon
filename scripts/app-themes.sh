#!/usr/bin/env bash
# app-themes.sh [--auto | --now | --setup]    the rice's colours in the apps that are not GTK / terminals:
#   Starship  the HALCYON PALETTE block at the bottom of ~/.config/starship.toml (the prompt, incl. the rice name)
#   btop      ~/.config/btop/themes/halcyon.theme
#   yazi      ~/.config/yazi/flavors/halcyon.yazi
#   Spotify   ~/.config/spicetify/Themes/halcyon  (spicetify; needs `spicetify apply`, which --now / --setup do)
#   Discord   Vesktop / Vencord theme file halcyon.theme.css (stock Discord cannot be themed: Vesktop is installed for that)
#   fish      static (config/fish/halcyon.fish uses the terminal's ANSI names, so it follows the wallpaper on its own)
# The colours are the island palette + the 16 terminal colours (term-colors.sh --export  ->  ~/.cache/island/ansi.env).
#   --auto    what the island runs after every wallpaper change (does nothing while ~/.local/state/island/app-follow is "off")
#   --now     regenerate everything now, and apply the Spotify theme
#   --setup   once, from install.sh: also point btop / yazi / spicetify / Vesktop at the halcyon theme (existing choices are backed up)
# Every app is skipped when it is not installed. Spotify and Discord stay dark: their themes use the wallpaper's dark palette.
mode="${1:---now}"
state="$HOME/.local/state/island"
here="$(cd "$(dirname "$0")" && pwd)"
RICE="${HALCYON_DIR:-$(dirname "$here")}"
[ "$mode" = "--auto" ] && [ "$(head -n1 "$state/app-follow" 2>/dev/null)" = "off" ] && exit 0
have() { command -v "$1" >/dev/null 2>&1; }

# a trace of every run (tail ~/.cache/island/app-themes.log): no line after a wallpaper change = the island did not start this script
mkdir -p "$HOME/.cache/island"
log() { echo "$(date +%T) $*" >> "$HOME/.cache/island/app-themes.log"; }
[ -f "$HOME/.cache/island/app-themes.log" ] && [ "$(wc -l < "$HOME/.cache/island/app-themes.log")" -gt 300 ] && { tail -n 100 "$HOME/.cache/island/app-themes.log" > "$HOME/.cache/island/app-themes.log.t"; mv "$HOME/.cache/island/app-themes.log.t" "$HOME/.cache/island/app-themes.log"; }
log "$mode start"

# ---- colours
bash "$here/term-colors.sh" --export >/dev/null 2>&1
env="$HOME/.cache/island/ansi.env"
[ -f "$env" ] || { log "no $env (term-colors.sh --export wrote nothing): stop"; exit 0; }
while IFS== read -r k v; do
  case "$k" in A_*) [[ "$v" =~ ^#[0-9a-fA-F]{6}$ ]] && declare "$k=$v" ;; esac
done < "$env"
[ -n "${A_BG:-}" ] && [ -n "${A_FG:-}" ] && [ -n "${A_ACC:-}" ] && [ -n "${A_C1:-}" ] || { log "ansi.env incomplete: stop"; exit 0; }
bg=$A_BG; fg=$A_FG; surf=$A_SURF; hi=$A_HI; mut=$A_MUTED; acc=$A_ACC; acc2=${A_ACC2:-$A_ACC}
red=$A_C1; green=$A_C2; yellow=$A_C3; blue=$A_C4; magenta=$A_C5; cyan=$A_C6

mixv() {   # mixv A B percent-of-B -> $MIX
  local a=${1#\#} b=${2#\#} p=$3
  printf -v MIX '#%02x%02x%02x' \
    $(( (16#${a:0:2} * (100 - p) + 16#${b:0:2} * p) / 100 )) \
    $(( (16#${a:2:2} * (100 - p) + 16#${b:2:2} * p) / 100 )) \
    $(( (16#${a:4:2} * (100 - p) + 16#${b:4:2} * p) / 100 ))
}
rgb() { local c=${1#\#}; printf '%d, %d, %d' $((16#${c:0:2})) $((16#${c:2:2})) $((16#${c:4:2})); }
nh() { echo "${1#\#}"; }
strip_block() {   # strip_block FILE BEGIN END : the file without the block between the two marker lines
  [ -f "$1" ] && awk -v b="$2" -v e="$3" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$1"
}

# ================================================================== Starship
starship_adopt() {   # make ~/.config/starship.toml use the halcyon palette: your layout is kept, only the colours are taken over
  have starship || return 0
  local f="$HOME/.config/starship.toml" B="# >>> HALCYON STARSHIP PALETTE >>>" E="# <<< HALCYON STARSHIP PALETTE <<<"
  grep -qF "$B" "$f" 2>/dev/null && return 0
  mkdir -p "$HOME/.config"
  if [ ! -f "$f" ]; then
    [ -f "$RICE/config/starship.toml" ] && cp "$RICE/config/starship.toml" "$f" && echo "   starship: Halcyon prompt installed"
    return 0
  fi
  [ -e "$f.before-halcyon" ] || cp -p "$f" "$f.before-halcyon"
  {
    echo 'palette = "halcyon"'
    # drop an older palette (Noctalia ...): its block, and any palette = line
    awk -v nb="# >>> NOCTALIA STARSHIP PALETTE >>>" -v ne="# <<< NOCTALIA STARSHIP PALETTE <<<" '$0==nb{skip=1;next} $0==ne{skip=0;next} !skip' "$f" | grep -vE '^[[:space:]]*#?[[:space:]]*palette[[:space:]]*='
    # the rice name next to your other stats (your right_format has $custom, which shows every [custom.*] module)
    grep -q '^\[custom\.halcyon\]' "$f" || printf '\n[custom.halcyon]\ncommand = "printf halcyon"\nwhen = true\nstyle = "bold italic accent"\nformat = "[◈ $output]($style) "\n'
    printf '\n%s\n%s\n' "$B" "$E"
  } > "$f.new" && mv "$f.new" "$f" && echo "   starship: your prompt now uses the wallpaper colours (your old file: starship.toml.before-halcyon)"
  return 0
}
starship_theme() {
  local f="$HOME/.config/starship.toml" B="# >>> HALCYON STARSHIP PALETTE >>>" E="# <<< HALCYON STARSHIP PALETTE <<<"
  [ -f "$f" ] && grep -qF "$B" "$f" || { log "starship: $f has no halcyon block (starship installed: $(have starship && echo yes || echo no))"; return 0; }
  local t="$f.tmp"
  {
    strip_block "$f" "$B" "$E"
    echo "$B"; echo "# written by scripts/app-themes.sh: do not edit this block"; echo "[palettes.halcyon]"
    # standard names (bright-* too, so every style in the file is covered)
    for pair in black:$A_C0 red:$A_C1 green:$A_C2 yellow:$A_C3 blue:$A_C4 magenta:$A_C5 purple:$A_C5 cyan:$A_C6 white:$A_C7 \
                bright-black:$A_C8 bright-red:$A_C9 bright-green:$A_C10 bright-yellow:$A_C11 bright-blue:$A_C12 bright-magenta:$A_C13 \
                bright-purple:$A_C13 bright-cyan:$A_C14 bright-white:$A_C15 accent:$acc accent2:$acc2 \
                rosewater:$acc2 flamingo:$red pink:$A_C13 mauve:$acc2 maroon:$red peach:$yellow teal:$cyan sky:$cyan sapphire:$blue lavender:$acc \
                text:$fg subtext1:$fg subtext0:$mut overlay2:$mut overlay1:$mut overlay0:$hi surface2:$hi surface1:$hi surface0:$surf \
                base:$bg mantle:$bg crust:$bg; do
      printf '%-15s = "%s"\n' "${pair%%:*}" "${pair#*:}"
    done
    echo "$E"
  } > "$t" && mv "$t" "$f" && log "starship: palette written (accent $acc, blue $A_C4)"
}

# ================================================================== fish
fish_theme() {
  have fish || return 0
  # the handler + Starship start-up: keep conf.d/halcyon.fish the same as the one in the rice
  if [ -f "$RICE/config/fish/halcyon.fish" ]; then
    mkdir -p "$HOME/.config/fish/conf.d"
    cmp -s "$RICE/config/fish/halcyon.fish" "$HOME/.config/fish/conf.d/halcyon.fish" || cp "$RICE/config/fish/halcyon.fish" "$HOME/.config/fish/conf.d/halcyon.fish"
  fi
  local f="$HOME/.cache/island/halcyon-colors.fish"
  {
    echo "# Halcyon: written by scripts/app-themes.sh from the wallpaper colours (loaded by conf.d/halcyon.fish)"
    echo "set -g fish_color_normal normal"
    echo "set -g fish_color_command $(nh "$acc")";         echo "set -g fish_color_keyword $(nh "$acc2")"
    echo "set -g fish_color_quote $(nh "$green")";         echo "set -g fish_color_redirection $(nh "$cyan")"
    echo "set -g fish_color_end $(nh "$acc2")";            echo "set -g fish_color_error $(nh "$red")"
    echo "set -g fish_color_param $(nh "$fg")";            echo "set -g fish_color_option $(nh "$cyan")"
    echo "set -g fish_color_comment $(nh "$mut")";         echo "set -g fish_color_autosuggestion $(nh "$mut")"
    echo "set -g fish_color_operator $(nh "$cyan")";       echo "set -g fish_color_escape $(nh "$cyan")"
    echo "set -g fish_color_valid_path --underline"
    echo "set -g fish_color_cwd $(nh "$acc")";             echo "set -g fish_color_cwd_root $(nh "$red")"
    echo "set -g fish_color_user $(nh "$cyan")";           echo "set -g fish_color_host $(nh "$acc")"
    echo "set -g fish_color_host_remote $(nh "$yellow")";  echo "set -g fish_color_status $(nh "$red")"
    echo "set -g fish_color_cancel $(nh "$mut")"
    echo "set -g fish_color_selection --background=$(nh "$hi")"; echo "set -g fish_color_search_match --background=$(nh "$hi")"
    echo "set -g fish_pager_color_prefix $(nh "$acc") --bold"; echo "set -g fish_pager_color_completion $(nh "$fg")"
    echo "set -g fish_pager_color_description $(nh "$mut")";   echo "set -g fish_pager_color_progress $(nh "$mut")"
    echo "set -g fish_pager_color_selected_background --background=$(nh "$hi")"
  } > "$f.tmp" && mv "$f.tmp" "$f" && log "fish: colours written (accent $acc)"
}

# ================================================================== btop
btop_theme() {
  have btop || return 0
  local d="$HOME/.config/btop/themes" g1 g2
  mkdir -p "$d"
  grad() {   # grad NAME LOW MID HIGH
    echo "theme[${1}_start]=\"$2\""; echo "theme[${1}_mid]=\"$3\""; echo "theme[${1}_end]=\"$4\""
  }
  {
    echo "# Halcyon: written by scripts/app-themes.sh from the wallpaper colours (do not edit: it is rewritten)"
    echo 'theme[main_bg]=""'                       # empty = the terminal's own background (keeps its blur / opacity)
    echo "theme[main_fg]=\"$fg\""; echo "theme[title]=\"$acc\""; echo "theme[hi_fg]=\"$acc\""
    echo "theme[selected_bg]=\"$hi\""; echo "theme[selected_fg]=\"$acc\""
    echo "theme[inactive_fg]=\"$mut\""; echo "theme[graph_text]=\"$fg\""; echo "theme[meter_bg]=\"$hi\""
    echo "theme[proc_misc]=\"$acc2\""
    mixv "$surf" "$acc" 45; local box=$MIX
    echo "theme[cpu_box]=\"$box\""; echo "theme[mem_box]=\"$box\""; echo "theme[net_box]=\"$box\""; echo "theme[proc_box]=\"$box\""
    echo "theme[div_line]=\"$box\""
    grad temp "$green" "$yellow" "$red"
    grad cpu "$green" "$yellow" "$red"
    mixv "$bg" "$green" 45; g1=$MIX; grad free "$g1" "$green" "$green"
    mixv "$bg" "$blue" 45;  g1=$MIX; grad cached "$g1" "$blue" "$blue"
    mixv "$bg" "$yellow" 45; g1=$MIX; grad available "$g1" "$yellow" "$yellow"
    mixv "$bg" "$red" 45;   g1=$MIX; grad used "$g1" "$red" "$red"
    mixv "$bg" "$blue" 40;  g1=$MIX; mixv "$blue" "$cyan" 50; g2=$MIX; grad download "$g1" "$g2" "$cyan"
    mixv "$bg" "$magenta" 40; g1=$MIX; mixv "$magenta" "$acc2" 50; g2=$MIX; grad upload "$g1" "$g2" "$acc2"
  } > "$d/halcyon.theme.tmp" && mv "$d/halcyon.theme.tmp" "$d/halcyon.theme" && log "btop: theme written (accent $acc)"
  return 0
}

# ================================================================== yazi
yazi_theme() {
  have yazi || return 0
  local d="$HOME/.config/yazi/flavors/halcyon.yazi" sec=mgr v
  v=$(yazi --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  # yazi renamed [manager] to [mgr] in 25.5
  [ -n "$v" ] && [ "$(printf '%s\n25.5.0\n' "$v" | sort -V | head -n1)" != "25.5.0" ] && sec=manager
  mkdir -p "$d"
  mixv "$bg" "$acc" 30; local selbg=$MIX
  cat > "$d/flavor.toml.tmp" <<Y
# Halcyon: written by scripts/app-themes.sh from the wallpaper colours (do not edit: it is rewritten)
[$sec]
cwd = { fg = "$acc" }
hovered = { fg = "$bg", bg = "$acc" }
preview_hovered = { underline = true }
find_keyword = { fg = "$yellow", bold = true, italic = true, underline = true }
find_position = { fg = "$magenta", bg = "reset", bold = true, italic = true }
marker_selected = { fg = "$green", bg = "$green" }
marker_copied = { fg = "$yellow", bg = "$yellow" }
marker_cut = { fg = "$red", bg = "$red" }
marker_marked = { fg = "$cyan", bg = "$cyan" }
tab_active = { fg = "$bg", bg = "$acc" }
tab_inactive = { fg = "$fg", bg = "$hi" }
border_symbol = "│"
border_style = { fg = "$mut" }

[mode]
normal_main = { fg = "$bg", bg = "$acc", bold = true }
normal_alt = { fg = "$acc", bg = "$hi" }
select_main = { fg = "$bg", bg = "$green", bold = true }
select_alt = { fg = "$green", bg = "$hi" }
unset_main = { fg = "$bg", bg = "$magenta", bold = true }
unset_alt = { fg = "$magenta", bg = "$hi" }

[status]
overall = { fg = "$fg", bg = "$surf" }
sep_left = { open = "", close = "" }
sep_right = { open = "", close = "" }
perm_sep = { fg = "$mut" }
perm_type = { fg = "$blue" }
perm_read = { fg = "$yellow" }
perm_write = { fg = "$red" }
perm_exec = { fg = "$green" }
progress_label = { fg = "$fg", bold = true }
progress_normal = { fg = "$acc", bg = "$hi" }
progress_error = { fg = "$red", bg = "$hi" }

[pick]
border = { fg = "$acc" }
active = { fg = "$magenta", bold = true }
inactive = {}

[input]
border = { fg = "$acc" }
title = {}
value = {}
selected = { reversed = true }

[cmp]
border = { fg = "$acc" }
active = { reversed = true }
inactive = {}

[tasks]
border = { fg = "$acc" }
title = {}
hovered = { fg = "$magenta", underline = true }

[which]
mask = { bg = "$surf" }
cand = { fg = "$cyan" }
rest = { fg = "$mut" }
desc = { fg = "$magenta" }
separator = "  "
separator_style = { fg = "$mut" }

[help]
on = { fg = "$magenta" }
run = { fg = "$cyan" }
hovered = { reversed = true, bold = true }
footer = { fg = "$fg", bg = "$surf" }

[notify]
title_info = { fg = "$green" }
title_warn = { fg = "$yellow" }
title_error = { fg = "$red" }

[filetype]
rules = [
  { mime = "image/*", fg = "$cyan" },
  { mime = "{audio,video}/*", fg = "$yellow" },
  { mime = "application/{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}", fg = "$magenta" },
  { mime = "application/{pdf,doc,rtf}", fg = "$green" },
  { name = "*", fg = "$fg" },
  { name = "*/", fg = "$acc" },
]
Y
  mv "$d/flavor.toml.tmp" "$d/flavor.toml"
  return 0
}

# ================================================================== Spotify (spicetify)
SP_LAUNCHER="$HOME/.local/share/spotify-launcher/install/usr/share/spotify"
spotify_theme() {
  have spicetify || return 0
  local d="$HOME/.config/spicetify/Themes/halcyon"
  mkdir -p "$d"
  mixv "$bg" "$fg" 8; local card=$MIX
  {
    echo "; Halcyon: written by scripts/app-themes.sh from the wallpaper colours (do not edit: it is rewritten)"
    echo "[base]"
    echo "text               = $(nh "$fg")";       echo "subtext            = $(nh "$mut")";     echo "sidebar-text       = $(nh "$fg")"
    echo "main               = $(nh "$bg")";       echo "main-elevated      = $(nh "$surf")";    echo "sidebar            = $(nh "$bg")"
    echo "player             = $(nh "$bg")";       echo "card               = $(nh "$card")";    echo "shadow             = $(nh "$bg")"
    echo "highlight          = $(nh "$hi")";       echo "highlight-elevated = $(nh "$hi")";     echo "selected-row       = $(nh "$fg")"
    echo "button             = $(nh "$acc")";      echo "button-active      = $(nh "$acc")";     echo "button-disabled    = $(nh "$mut")"
    echo "tab-active         = $(nh "$hi")";       echo "notification       = $(nh "$hi")";      echo "notification-error = $(nh "$red")"
    echo "equalizer          = $(nh "$acc")";      echo "misc               = $(nh "$hi")"
    echo "play-button        = $(nh "$acc")";      echo "play-button-active = $(nh "$acc")";     echo "progress-fg        = $(nh "$acc")"
    echo "progress-bg        = $(nh "$hi")";       echo "heart              = $(nh "$red")";     echo "pagelink-active    = $(nh "$acc")"
    echo "radio-btn-active   = $(nh "$acc")"
  } > "$d/color.ini.tmp" && mv "$d/color.ini.tmp" "$d/color.ini"
  [ -f "$d/user.css" ] || echo "/* Halcyon: colours only (color.ini). Add your own CSS here. */" > "$d/user.css"
}
spotify_apply() {   # a theme is only visible after `spicetify apply`; Spotify's UI restarts when it is open
  have spicetify || return 0
  local prefs="$HOME/.config/spotify/prefs"
  [ -f "$prefs" ] || { [ "$mode" = "--setup" ] && echo "   spicetify: start Spotify once and log in, then run  ~/.config/Halcyon/scripts/app-themes.sh --now"; return 0; }
  spicetify apply >/dev/null 2>&1 || spicetify backup apply >/dev/null 2>&1
}
spotify_setup() {
  have spicetify || return 0
  spicetify >/dev/null 2>&1                                  # first run makes its config file
  # spotify-launcher keeps the client in your home: tell spicetify where
  [ -d "$SP_LAUNCHER" ] && spicetify config spotify_path "$SP_LAUNCHER" >/dev/null 2>&1
  [ -f "$HOME/.config/spotify/prefs" ] && spicetify config prefs_path "$HOME/.config/spotify/prefs" >/dev/null 2>&1
  spicetify config current_theme halcyon color_scheme base inject_css 1 replace_colors 1 overwrite_assets 1 >/dev/null 2>&1
}

# ================================================================== Discord (Vesktop / Vencord)
discord_theme() {
  local base
  mixv "$bg" "$fg" 5; local hov=$MIX
  for base in "$HOME/.config/vesktop" "$HOME/.config/Vencord"; do
    [ -d "$base" ] || { [ "$base" = "$HOME/.config/vesktop" ] && have vesktop && mkdir -p "$base" || continue; }
    mkdir -p "$base/themes"
    cat > "$base/themes/halcyon.theme.css.tmp" <<CSS
/**
 * @name Halcyon
 * @description The Halcyon rice colours (follows the wallpaper). Written by scripts/app-themes.sh: it is rewritten, do not edit.
 * @version 1
 */
:root, .theme-dark, .theme-darker, .theme-light, .theme-midnight {
  --h-bg: $bg; --h-surf: $surf; --h-hi: $hi; --h-fg: $fg; --h-mut: $mut; --h-acc: $acc; --h-acc2: $acc2; --h-red: $red; --h-green: $green; --h-yellow: $yellow;
  /* surfaces (older + newer Discord variable names) */
  --background-primary: var(--h-bg) !important;
  --background-secondary: var(--h-surf) !important;
  --background-secondary-alt: var(--h-surf) !important;
  --background-tertiary: var(--h-bg) !important;
  --background-floating: var(--h-surf) !important;
  --background-accent: var(--h-hi) !important;
  --background-base-low: var(--h-bg) !important;
  --background-base-lower: var(--h-surf) !important;
  --background-base-lowest: var(--h-bg) !important;
  --background-surface-high: var(--h-surf) !important;
  --background-surface-higher: var(--h-hi) !important;
  --background-surface-highest: var(--h-hi) !important;
  --chat-background-default: var(--h-bg) !important;
  --channeltextarea-background: var(--h-surf) !important;
  --input-background: var(--h-surf) !important;
  --modal-background: var(--h-surf) !important;
  --modal-footer-background: var(--h-bg) !important;
  --background-modifier-hover: rgba($(rgb "$hov"), 0.55) !important;
  --background-modifier-selected: rgba($(rgb "$acc"), 0.20) !important;
  --background-modifier-active: rgba($(rgb "$acc"), 0.28) !important;
  --background-modifier-accent: rgba($(rgb "$mut"), 0.18) !important;
  --bg-overlay-1: var(--h-bg) !important; --bg-overlay-2: var(--h-surf) !important; --bg-overlay-3: var(--h-surf) !important;
  --bg-overlay-4: var(--h-bg) !important; --bg-overlay-5: var(--h-surf) !important; --bg-overlay-6: var(--h-bg) !important;
  /* text */
  --text-normal: var(--h-fg) !important; --text-default: var(--h-fg) !important; --text-strong: var(--h-fg) !important;
  --text-muted: var(--h-mut) !important; --text-subtle: var(--h-mut) !important;
  --header-primary: var(--h-fg) !important; --header-secondary: var(--h-mut) !important;
  --interactive-normal: var(--h-mut) !important; --interactive-hover: var(--h-fg) !important; --interactive-active: var(--h-acc) !important;
  --interactive-muted: var(--h-hi) !important; --interactive-text-default: var(--h-mut) !important;
  --channels-default: var(--h-mut) !important; --channel-icon: var(--h-mut) !important;
  --text-link: var(--h-acc) !important; --text-brand: var(--h-acc) !important;
  /* accent */
  --brand-experiment: var(--h-acc) !important; --brand-500: var(--h-acc) !important; --brand-360: var(--h-acc) !important;
  --brand-experiment-560: var(--h-acc) !important; --brand-experiment-600: var(--h-acc) !important;
  --background-brand: var(--h-acc) !important; --button-filled-brand-background: var(--h-acc) !important;
  --button-filled-brand-text: var(--h-bg) !important; --mention-foreground: var(--h-acc) !important;
  --mention-background: rgba($(rgb "$acc"), 0.18) !important;
  --status-positive: var(--h-green) !important; --status-warning: var(--h-yellow) !important; --status-danger: var(--h-red) !important;
  --scrollbar-thin-thumb: var(--h-hi) !important; --scrollbar-auto-thumb: var(--h-hi) !important; --scrollbar-auto-track: transparent !important;
}
CSS
    mv "$base/themes/halcyon.theme.css.tmp" "$base/themes/halcyon.theme.css"
  done
}

# ================================================================== --setup: choose the halcyon theme (once)
ensure_choices() {
  local f
  # btop: color_theme = "halcyon"
  if have btop; then
    f="$HOME/.config/btop/btop.conf"; mkdir -p "$(dirname "$f")"
    if [ -f "$f" ]; then
      grep -q '^color_theme *= *"halcyon"' "$f" || { [ -e "$f.before-halcyon" ] || cp -p "$f" "$f.before-halcyon"
        if grep -q '^color_theme' "$f"; then sed -i 's|^color_theme.*|color_theme = "halcyon"|' "$f"; else echo 'color_theme = "halcyon"' >> "$f"; fi; }
    else echo 'color_theme = "halcyon"' > "$f"; fi
    echo "   btop: theme halcyon"
  fi
  # yazi: [flavor] dark / light = "halcyon"
  if have yazi; then
    f="$HOME/.config/yazi/theme.toml"; mkdir -p "$(dirname "$f")"
    if [ ! -f "$f" ]; then printf '[flavor]\ndark = "halcyon"\nlight = "halcyon"\n' > "$f"
    elif ! grep -q 'halcyon' "$f"; then
      [ -e "$f.before-halcyon" ] || cp -p "$f" "$f.before-halcyon"
      if grep -q '^\[flavor\]' "$f"; then
        sed -i '/^\[flavor\]/,/^\[/{/^dark *=/d;/^light *=/d}' "$f"; sed -i '/^\[flavor\]/a dark = "halcyon"\nlight = "halcyon"' "$f"
      else { printf '[flavor]\ndark = "halcyon"\nlight = "halcyon"\n\n'; cat "$f"; } > "$f.new" && mv "$f.new" "$f"; fi
    fi
    echo "   yazi: flavor halcyon"
  fi
  # Vesktop / Vencord: enable the theme
  if command -v jq >/dev/null 2>&1; then
    for base in "$HOME/.config/vesktop" "$HOME/.config/Vencord"; do
      [ -f "$base/themes/halcyon.theme.css" ] || continue
      f="$base/settings/settings.json"; mkdir -p "$base/settings"; [ -s "$f" ] || echo '{}' > "$f"
      jq '.enabledThemes = ((.enabledThemes // []) + ["halcyon.theme.css"] | unique)' "$f" > "$f.new" 2>/dev/null && mv "$f.new" "$f" && echo "   $(basename "$base"): theme halcyon enabled"
    done
  fi
}

# every run: pick the halcyon theme where an app still has another one (existing choices are backed up once), then write the files
starship_adopt
starship_theme; fish_theme; btop_theme; yazi_theme; spotify_theme; discord_theme
ensure_choices >/dev/null          # after the files exist (Vesktop needs its theme file first)
have btop && pkill -USR2 -x btop 2>/dev/null     # a running btop re-reads its config and theme
if [ "$mode" = "--setup" ]; then ensure_choices; spotify_setup; fi
if [ "$mode" = "--now" ] || [ "$mode" = "--setup" ]; then spotify_apply
elif ! pgrep -x spotify >/dev/null 2>&1; then spotify_apply; fi    # --auto: only while Spotify is closed (applying restarts its UI)
log "$mode done"
exit 0
