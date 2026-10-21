#!/usr/bin/env bash
# app-themes.sh [--auto | --now | --setup]    the rice's colours in the apps that are not GTK / terminals:
#   Starship  the HALCYON PALETTE block at the bottom of ~/.config/starship.toml (the prompt, incl. the rice name)
#   btop      ~/.config/btop/themes/halcyon.theme
#   yazi      ~/.config/yazi/flavors/halcyon.yazi
#   micro     ~/.config/micro/colorschemes/halcyon.micro  (no background colour: the terminal's own blur / opacity shows through)
#   Spotify   ~/.config/spicetify/Themes/halcyon  (spicetify; needs `spicetify apply`, which --now / --setup do)
#   spotify-player  ~/.config/spotify-player/theme.toml (the terminal Spotify client; re-read every time it starts)
#   Discord   Vesktop / Vencord theme file halcyon.theme.css (stock Discord cannot be themed: Vesktop is installed for that)
#   fish      static (config/fish/halcyon.fish uses the terminal's ANSI names, so it follows the wallpaper on its own)
#   + scripts/app-themes-extra.sh: VSCodium / Code - OSS / VS Code / Cursor, Zed, Firefox / Zen / LibreWolf / Floorp, Qt apps (Dolphin, Kate)
# The colours are the island palette + the 16 terminal colours (term-colors.sh --export  ->  ~/.cache/island/ansi.env).
#   --auto    what the island runs after every wallpaper change (does nothing while ~/.local/state/island/app-follow is "off")
#   --now     regenerate everything now, and apply the Spotify theme
#   --setup   once, from install.sh: also point btop / yazi / spicetify / Vesktop at the halcyon theme (existing choices are backed up),
#             and carry out the prompt choice of install.sh (--prompt keep | colours | halcyon, asked once, saved as PROMPT in
#             ~/.local/state/island/install-choices.env): "keep" never touches your Starship at all
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
while IFS='=' read -r k v; do
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
# the installer's prompt choice: keep | colours | halcyon, or empty (an install from before the question existed: handled as it always was)
prompt_choice() {
  local c="${HALCYON_PROMPT:-}"
  [ -n "$c" ] || c=$(sed -n 's/^PROMPT="\(.*\)"$/\1/p' "$state/install-choices.env" 2>/dev/null | tail -n1)
  case "$c" in keep|colours|halcyon) echo "$c" ;; *) echo "" ;; esac
}
is_full_halcyon() { [ -f "$1" ] && grep -qF '[◈ halcyon](bold italic accent)' "$1" 2>/dev/null; }   # Halcyon's own prompt file (not just your layout with its colours)
# --setup: carry out the choice. keep = hands off (conf.d/halcyon.fish then does not start Starship either: the marker file keep-prompt),
# colours = your layout + the wallpaper colours, halcyon = the rice's prompt. Whatever is replaced is saved next to it, so every switch can be undone.
starship_choice() {
  local f="$HOME/.config/starship.toml" B="# >>> HALCYON STARSHIP PALETTE >>>" c
  c=$(prompt_choice); [ -n "$c" ] || return 0
  mkdir -p "$state"
  case "$c" in
    keep)
      touch "$state/keep-prompt"
      if [ -f "$f" ] && grep -qF "$B" "$f" 2>/dev/null; then       # an earlier install put Halcyon's colours / prompt in your file: give yours back
        if [ -f "$f.before-halcyon" ]; then
          cp -p "$f" "$f.halcyon" && cp -p "$f.before-halcyon" "$f" && echo "   starship: your own prompt is back (Halcyon's is saved as starship.toml.halcyon)"
        else
          mv "$f" "$f.halcyon" && echo "   starship: Halcyon's prompt file moved aside to starship.toml.halcyon (Starship uses its own defaults again)"
        fi
      else
        echo "   starship: your prompt is left alone"
      fi ;;
    colours)
      rm -f "$state/keep-prompt"
      if is_full_halcyon "$f" && [ -f "$f.before-halcyon" ]; then    # back to your layout first: starship_adopt then adds only the colours
        cp -p "$f" "$f.halcyon" && cp -p "$f.before-halcyon" "$f"
      fi ;;
    halcyon)
      rm -f "$state/keep-prompt"
      if ! is_full_halcyon "$f" && [ -f "$RICE/config/starship.toml" ]; then
        mkdir -p "$HOME/.config"
        [ -f "$f" ] && [ ! -e "$f.before-halcyon" ] && cp -p "$f" "$f.before-halcyon"
        cp "$RICE/config/starship.toml" "$f" && echo "   starship: Halcyon prompt installed$([ -e "$f.before-halcyon" ] && echo ' (your old file: starship.toml.before-halcyon)')"
      fi ;;
  esac
}
starship_adopt() {   # make ~/.config/starship.toml use the halcyon palette: your layout is kept, only the colours are taken over
  have starship || return 0
  case "$(prompt_choice)" in keep|halcyon) return 0 ;; esac    # keep: not yours to touch.  halcyon: the whole file is the rice's (starship_choice)
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
# an installed ~/.config/starship.toml is never replaced (it is yours), so swap ONLY the old [custom.sysmode] table (it ran
# `sysmode status` before every prompt and showed [mx] for the old "cyber" mode name, or the first fix that was missing
# `shell = ["sh"]`, so Starship ran it in fish and it printed nothing) for the one in the rice
starship_sysmode_migrate() {
  local f="$HOME/.config/starship.toml" src="$RICE/config/starship.toml" blk
  [ "$(prompt_choice)" = keep ] && return 0
  [ -f "$f" ] && [ -f "$src" ] || return 0
  grep -q '^\[custom\.sysmode\]' "$f" 2>/dev/null || return 0
  grep -qF "halcyon-sysmode-badge v2" "$f" 2>/dev/null && return 0
  # only the two commands the rice itself shipped (the very first one and the one without `shell = ["sh"]`), never one you wrote
  grep -qF "sysmode status | grep 'Mode:'" "$f" 2>/dev/null || grep -qF "read -r m < /etc/sysmode.mode" "$f" 2>/dev/null || return 0
  blk=$(mktemp) || return 0
  awk '/^\[custom\.sysmode\]/{p=1} p && /^# >>> HALCYON/{exit} p' "$src" > "$blk"
  grep -q '^\[custom\.sysmode\]' "$blk" || { rm -f "$blk"; return 0; }
  [ -e "$f.before-sysmode-fix" ] || cp -p "$f" "$f.before-sysmode-fix"
  awk -v blk="$blk" '
    /^\[custom\.sysmode\]/ { while ((getline l < blk) > 0) print l; skip=1; next }
    skip && (/^\[/ || /^# >>>/) { skip=0 }
    !skip { print }' "$f" > "$f.new" && mv "$f.new" "$f" && echo "   starship: sysmode badge updated (your old file: starship.toml.before-sysmode-fix)"
  rm -f "$blk"
}
# The sysmode badge asks sysmode for the mode before every prompt. Without sysmode there is nothing to ask, so the badge is switched OFF
# (disabled = true: Starship then starts no shell for it at all) and switched on again as soon as sysmode is installed. Only the table that
# carries Halcyon's own marker is touched; one you wrote yourself is not.
starship_sysmode_sync() {
  local f="$HOME/.config/starship.toml" want
  [ -f "$f" ] && grep -qF "halcyon-sysmode-badge" "$f" 2>/dev/null || return 0
  [ "$(prompt_choice)" = keep ] && return 0
  if [ -x /usr/local/bin/sysmode ] || have sysmode; then want=on; else want=off; fi
  awk -v want="$want" '
    /^\[/ { intab = ($0 == "[custom.sysmode]"); print; if (intab && want == "off") print "disabled = true"; next }
    intab && /^[[:space:]]*disabled[[:space:]]*=/ { next }
    { print }' "$f" > "$f.new" 2>/dev/null || { rm -f "$f.new"; return 0; }
  if cmp -s "$f" "$f.new"; then rm -f "$f.new"
  else mv "$f.new" "$f" && echo "   starship: sysmode badge $([ "$want" = on ] && echo 'on (sysmode is installed)' || echo 'off (sysmode is not installed: nothing is checked before every prompt)')"; fi
}
starship_theme() {
  local f="$HOME/.config/starship.toml" B="# >>> HALCYON STARSHIP PALETTE >>>" E="# <<< HALCYON STARSHIP PALETTE <<<"
  [ "$(prompt_choice)" = keep ] && return 0
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

# ================================================================== micro
# micro paints its own background (the default scheme is an opaque grey, and its status bar and current line are grey bars), which
# hides the wallpaper behind a translucent terminal. This scheme gives NO background to the text, the status bar, the tabs and the
# gutter, so the terminal's own background (foot / kitty ... alpha + the compositor's blur) shows through. Colours are the
# wallpaper's bright ones, so they stay readable on top of it. Only the current line, the selection and search hits get a background.
# A colour given alone ("#rrggbb") is a foreground only; "fg,bg" sets both.
micro_theme() {
  have micro || return 0
  local d="$HOME/.config/micro/colorschemes" cur sel dim bred bgreen byellow bblue bmagenta bcyan
  mkdir -p "$d"
  bred=${A_C9:-$red}; bgreen=${A_C10:-$green}; byellow=${A_C11:-$yellow}; bblue=${A_C12:-$blue}; bmagenta=${A_C13:-$magenta}; bcyan=${A_C14:-$cyan}
  mixv "$bg" "$acc" 24; cur=$MIX            # the line the cursor is on: the background colour pulled a little towards the accent (darker than the text, never the text colour)
  mixv "$hi" "$acc" 40; sel=$MIX            # the selection
  mixv "$mut" "$fg" 30; dim=$MIX            # comments / line numbers: the muted colour, lifted a little so it stays readable
  {
    echo "# Halcyon: written by scripts/app-themes.sh from the wallpaper colours (do not edit: it is rewritten)"
    echo "# No background on purpose: the terminal's own (translucent) one shows through. Restart micro to see a new wallpaper's colours."
    echo "color-link default \"$fg\""
    echo "color-link comment \"$dim\""
    echo "color-link identifier \"$bblue\""
    echo "color-link constant \"$bcyan\""
    echo "color-link constant.string \"$bgreen\""
    echo "color-link constant.specialChar \"$byellow\""
    echo "color-link statement \"bold $bmagenta\""
    echo "color-link symbol \"$fg\""
    echo "color-link preproc \"$acc2\""
    echo "color-link type \"$byellow\""
    echo "color-link type.extended \"$byellow\""
    echo "color-link special \"$acc\""
    echo "color-link underlined \"underline $bcyan\""
    echo "color-link error \"bold $bred\""
    echo "color-link todo \"bold $byellow\""
    echo "color-link hlsearch \"$bg,$acc\""
    echo "color-link statusline \"bold $acc\""
    echo "color-link tabbar \"$dim\""
    echo "color-link tabbar.active \"bold $acc\""
    echo "color-link indent-char \"$dim\""
    echo "color-link line-number \"$dim\""
    echo "color-link current-line-number \"bold $acc\""
    echo "color-link diff-added \"$bgreen\""
    echo "color-link diff-modified \"$byellow\""
    echo "color-link diff-deleted \"$bred\""
    echo "color-link gutter-error \"bold $bred\""
    echo "color-link gutter-warning \"$byellow\""
    echo "color-link divider \"$dim\""
    # micro paints the current line / colour column with the FOREGROUND colour of these two groups (that is how its own schemes
    # write them, one colour alone), so give them just the dark tint: "fg,bg" here made the line the colour of the text
    echo "color-link cursor-line \"$cur\""
    echo "color-link color-column \"$cur\""
    echo "color-link selection \"$fg,$sel\""
  } > "$d/halcyon.micro.tmp" && mv "$d/halcyon.micro.tmp" "$d/halcyon.micro" && log "micro: colorscheme written (accent $acc)"
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

# ================================================================== spotify-player (terminal Spotify client)
spotify_player_theme() {
  have spotify_player || return 0
  local d="$HOME/.config/spotify-player" f B="# >>> HALCYON SPOTIFY-PLAYER THEME >>>" E="# <<< HALCYON SPOTIFY-PLAYER THEME <<<" brd
  f="$d/theme.toml"; mkdir -p "$d"
  mixv "$surf" "$acc" 45; brd=$MIX
  {
    strip_block "$f" "$B" "$E"        # your own themes in the same file are kept; only this block is rewritten
    echo "$B"
    echo "# written by scripts/app-themes.sh from the wallpaper colours: do not edit this block (it is rewritten)"
    echo "[[themes]]"
    echo 'name = "halcyon"'
    echo "[themes.palette]"
    # no background on purpose: the terminal's own (foot's blur / opacity) shows through, like btop
    echo "foreground = \"$fg\""
    for pair in black:$A_C0 red:$A_C1 green:$A_C2 yellow:$A_C3 blue:$A_C4 magenta:$A_C5 cyan:$A_C6 white:$A_C7 \
                bright_black:$A_C8 bright_red:$A_C9 bright_green:$A_C10 bright_yellow:$A_C11 bright_blue:$A_C12 \
                bright_magenta:$A_C13 bright_cyan:$A_C14 bright_white:$A_C15; do
      [ -n "${pair#*:}" ] && printf '%s = "%s"\n' "${pair%%:*}" "${pair#*:}"
    done
    echo "[themes.component_style]"
    echo "block_title = { fg = \"$acc\", modifiers = [\"Bold\"] }"
    echo "border = { fg = \"$brd\" }"
    echo "playback_status = { fg = \"$acc\", modifiers = [\"Bold\"] }"
    echo "playback_track = { fg = \"$fg\", modifiers = [\"Bold\"] }"
    echo "playback_artists = { fg = \"$acc\", modifiers = [\"Bold\"] }"
    echo "playback_album = { fg = \"$acc2\" }"
    echo "playback_genres = { fg = \"$mut\", modifiers = [\"Italic\"] }"
    echo "playback_metadata = { fg = \"$mut\" }"
    echo "playback_progress_bar = { fg = \"$acc\", bg = \"$hi\" }"
    echo "playback_progress_bar_unfilled = { bg = \"$hi\" }"
    echo "current_playing = { fg = \"$acc\", modifiers = [\"Bold\"] }"
    echo "page_desc = { fg = \"$acc\", modifiers = [\"Bold\"] }"
    echo "playlist_desc = { fg = \"$mut\", modifiers = [\"Dim\"] }"
    echo "table_header = { fg = \"$acc2\", modifiers = [\"Bold\"] }"
    echo "selection = { fg = \"$bg\", bg = \"$acc\", modifiers = [\"Bold\"] }"
    echo "like = { fg = \"$red\" }"
    echo "lyrics_played = { fg = \"$mut\" }"
    echo "lyrics_playing = { fg = \"$acc\", modifiers = [\"Bold\"] }"
    echo "visualization = { low = \"$cyan\", mid = \"$acc\", high = \"$acc2\" }"
    echo "$E"
  } > "$f.tmp" && mv "$f.tmp" "$f" && log "spotify-player: theme written (accent $acc)"
  return 0
}

# ================================================================== Spotify (spicetify)
SP_LAUNCHER="$HOME/.local/share/spotify-launcher/install/usr/share/spotify"
# Shared by the Spotify and Discord themes: the same few steps of depth, so both apps look like part of the island.
#   T_BASE  the deepest layer (window background, rails)     T_SIDE  side panels      bg  the main surface      surf  cards, inputs, menus
#   T_LINE  a hairline outline (fg at a few %, never a solid border)      T_HOVER  hover wash      ON_ACC  the colour of an icon / text ON the accent
lum() { local c=${1#\#}; echo $(( (299 * 16#${c:0:2} + 587 * 16#${c:2:2} + 114 * 16#${c:4:2}) / 1000 )); }
rgba_of() { printf 'rgba(%s, %s)' "$(rgb "$1")" "$2"; }      # rgba_of #rrggbb 0.08
app_tones() {
  mixv "$bg" "#000000" 32; T_BASE=$MIX
  mixv "$bg" "#000000" 14; T_SIDE=$MIX
  T_LINE=$(rgba_of "$fg" 0.08); T_LINE2=$(rgba_of "$fg" 0.14); T_HOVER=$(rgba_of "$fg" 0.07)
  T_SEL=$(rgba_of "$acc" 0.16); T_SEL2=$(rgba_of "$acc" 0.26)
  # an accent that is light needs dark icons on it, a dark one needs light icons (before, the icon colour was always the background colour: invisible on a dark accent)
  if [ "$(lum "$acc")" -gt 150 ]; then mixv "$bg" "#000000" 55; ON_ACC=$MIX; else ON_ACC=$fg; fi
}
spotify_theme() {
  have spicetify || return 0
  local d="$HOME/.config/spicetify/Themes/halcyon"
  mkdir -p "$d"
  app_tones
  mixv "$bg" "$fg" 8; local hov=$MIX
  mixv "$bg" "$fg" 13; local hov2=$MIX
  mixv "$bg" "$fg" 20; local rail=$MIX
  {
    echo "; Halcyon: written by scripts/app-themes.sh from the wallpaper colours (do not edit: it is rewritten)"
    echo "[base]"
    echo "text               = $(nh "$fg")";       echo "subtext            = $(nh "$mut")";     echo "sidebar-text       = $(nh "$fg")"
    echo "main               = $(nh "$bg")";       echo "main-elevated      = $(nh "$surf")";    echo "sidebar            = $(nh "$bg")"
    echo "player             = $(nh "$bg")";       echo "card               = $(nh "$surf")";    echo "shadow             = $(nh "$T_BASE")"
    echo "highlight          = $(nh "$hov")";      echo "highlight-elevated = $(nh "$hov2")";    echo "selected-row       = $(nh "$fg")"
    echo "button             = $(nh "$acc")";      echo "button-active      = $(nh "$acc")";     echo "button-disabled    = $(nh "$mut")"
    echo "tab-active         = $(nh "$hov2")";     echo "notification       = $(nh "$surf")";    echo "notification-error = $(nh "$red")"
    echo "equalizer          = $(nh "$acc")";      echo "misc               = $(nh "$rail")"
    echo "play-button        = $(nh "$acc")";      echo "play-button-active = $(nh "$acc")";     echo "progress-fg        = $(nh "$acc")"
    echo "progress-bg        = $(nh "$rail")";     echo "heart              = $(nh "$acc")";     echo "pagelink-active    = $(nh "$acc")"
    echo "radio-btn-active   = $(nh "$acc")"
  } > "$d/color.ini.tmp" && mv "$d/color.ini.tmp" "$d/color.ini"
  # user.css: the Halcyon shape. Only the marked block is rewritten: your own CSS below it stays.
  # Design: the window is a night sky (faint stars, an accent glow, and the cover of what plays, blurred, behind everything: theme.js);
  # the library, the main view and the side panel float on it as rounded glass cards, the player is a glass island at the bottom.
  # The accent is only for what is selected / playing / primary. Icons keep their shapes; only their colour changes.
  local B="/* >>> halcyon >>> */" E="/* <<< halcyon <<< */" u="$d/user.css"
  local RF RA RA2 RB RS RBASE
  RF=$(rgb "$fg"); RA=$(rgb "$acc"); RA2=$(rgb "$acc2"); RB=$(rgb "$bg"); RS=$(rgb "$surf"); RBASE=$(rgb "$T_BASE")
  {
    strip_block "$u" "$B" "$E"
    cat <<CSS
$B
/* written by scripts/app-themes.sh: do not edit this block (Spotify renames classes now and then: a rule that stops matching is harmless) */
:root {
  --h-line: $T_LINE; --h-line2: $T_LINE2; --h-hover: $T_HOVER; --h-sel: $T_SEL; --h-on-acc: $ON_ACC; --h-acc: $acc; --h-acc2: $acc2;
  --h-glass: rgba($RB, 0.70); --h-glass-side: rgba($RB, 0.62); --h-glass-pop: rgba($RS, 0.92); --h-base: $T_BASE;
  --h-glow: 0 0 0 1px rgba($RA, 0.55), 0 0 22px rgba($RA, 0.25); --h-shadow: 0 10px 30px rgba(0, 0, 0, 0.35);
}
html body, html body button, html body input { font-family: "Inter", "SpotifyMixUI", "CircularSp", sans-serif !important; }

/* ---- the sky: stars, an accent glow, and the blurred cover of the song that plays (theme.js sets --halcyon-cover) ---- */
.Root__top-container {
  background:
    radial-gradient(1px 1px at 8% 14%, rgba($RF, 0.55), transparent 60%), radial-gradient(1px 1px at 23% 71%, rgba($RF, 0.35), transparent 60%),
    radial-gradient(1.5px 1.5px at 41% 33%, rgba($RF, 0.45), transparent 60%), radial-gradient(1px 1px at 57% 88%, rgba($RF, 0.30), transparent 60%),
    radial-gradient(1px 1px at 68% 9%, rgba($RF, 0.50), transparent 60%), radial-gradient(1.5px 1.5px at 79% 57%, rgba($RA, 0.55), transparent 60%),
    radial-gradient(1px 1px at 91% 26%, rgba($RF, 0.40), transparent 60%), radial-gradient(1px 1px at 4% 92%, rgba($RA2, 0.45), transparent 60%),
    radial-gradient(ellipse 60% 45% at 100% 0%, rgba($RA, 0.14), transparent 70%),
    radial-gradient(ellipse 55% 50% at 0% 100%, rgba($RA2, 0.10), transparent 70%),
    var(--h-base) !important;
  gap: 8px !important; padding: 0 8px 8px !important; isolation: isolate;
}
.Root__top-container::before {
  content: ""; position: fixed; inset: -12%; z-index: -1; pointer-events: none;
  background: var(--halcyon-cover, none) center / cover no-repeat;
  filter: blur(90px) saturate(1.35); opacity: 0.38; transition: background-image .8s ease, opacity .8s ease;
}
.Root__globalNav, .main-globalNav-container { background: transparent !important; }

/* ---- floating glass cards ---- */
.Root__nav-bar, .Root__main-view, .Root__right-sidebar, .main-yourLibraryX-libraryContainer, .main-yourLibraryX-entryPoints {
  border-radius: 16px !important; overflow: hidden !important; }
.Root__nav-bar, .Root__main-view, .Root__right-sidebar {
  background: var(--h-glass) !important; backdrop-filter: blur(20px) saturate(1.15);
  box-shadow: inset 0 0 0 1px var(--h-line), var(--h-shadow) !important; border: 0 !important; }
.Root__nav-bar { background: var(--h-glass-side) !important; }
.main-yourLibraryX-libraryContainer, .main-yourLibraryX-entryPoints, .main-yourLibraryX-library, .main-view-container,
.main-yourLibraryX-libraryItemContainer, .Root__right-sidebar > *, .main-home-content, .main-entityHeader-container, .main-topBar-container,
.main-topBar-background, .contentSpacing, .main-actionBarBackground-background { background: transparent !important; }
.main-entityHeader-background, .main-entityHeader-backgroundColor { background: linear-gradient(180deg, rgba($RA, 0.28) 0%, transparent 100%) !important; }
.main-actionBarBackground-background { background-image: none !important; }

/* ---- search: a glass pill that glows while you type ---- */
.main-globalNav-searchInputContainer input, .main-globalNav-searchContainer input, .x-searchInput-searchInputInput {
  background: rgba($RS, 0.75) !important; backdrop-filter: blur(14px); border: 0 !important; border-radius: 999px !important;
  box-shadow: inset 0 0 0 1px var(--h-line2) !important; }
.main-globalNav-searchInputContainer input:focus, .x-searchInput-searchInputInput:focus { box-shadow: var(--h-glow) !important; }
.main-globalNav-historyButtonsContainer button, .main-globalNav-link-icon { background: rgba($RS, 0.6) !important; border-radius: 999px !important; }

/* ---- cards: flat, a glass wash on hover, the play button glows ---- */
.main-card-card, .main-cardImage-imageWrapper, .main-cardImage-image { border-radius: 12px !important; }
.main-card-card { background: transparent !important; transition: background .2s ease, box-shadow .2s ease !important; }
.main-card-card:hover { background: rgba($RS, 0.55) !important; box-shadow: inset 0 0 0 1px var(--h-line) !important; }
.main-shelf-shelf .main-shelf-title, .main-shelf-header h2 { letter-spacing: -0.01em; }
/* the round primary play buttons (on cards and page headers): the accent with a soft glow; the small icon-only one on the shortcut tiles is left alone */
[data-encore-id="buttonPrimary"] > span, .main-playPauseButton-button { background-color: var(--h-acc) !important; color: var(--h-on-acc) !important;
  box-shadow: 0 6px 18px rgba($RA, 0.38) !important; }
[data-encore-id="buttonPrimary"] > span svg, .main-playPauseButton-button svg { fill: currentColor !important; color: var(--h-on-acc) !important; }
[data-encore-id="buttonPrimary"]:hover > span, .main-playPauseButton-button:hover { filter: brightness(1.08); box-shadow: 0 8px 24px rgba($RA, 0.5) !important; }

/* ---- the library and track rows ---- */
.main-yourLibraryX-listItem a, .main-yourLibraryX-listRow, .main-trackList-trackListRow { border-radius: 10px !important; }
.main-yourLibraryX-listItem:hover, .main-yourLibraryX-listRow:hover, .main-trackList-trackListRow:hover { background: var(--h-hover) !important; }
.main-yourLibraryX-listItemActive, .main-yourLibraryX-listRow[aria-selected="true"], .main-trackList-selected, .main-trackList-active {
  background: linear-gradient(90deg, rgba($RA, 0.22), rgba($RA, 0.05)) !important; box-shadow: inset 2px 0 0 var(--h-acc) !important; }
.main-trackList-playingIcon { filter: none !important; }
.main-trackList-trackListRow[aria-selected="true"] .main-trackList-rowTitle, .main-trackList-active .main-trackList-rowTitle { color: var(--h-acc) !important; }
.main-trackList-trackListHeader { background: transparent !important; box-shadow: 0 1px 0 var(--h-line) !important; }
/* filter chips (All / Music / Playlists ...): a glass pill, the chosen one in the accent */
[data-encore-id="chip"] > span { background: rgba($RS, 0.7) !important; box-shadow: inset 0 0 0 1px var(--h-line) !important; color: $fg !important; }
[data-encore-id="chip"][aria-checked="true"] > span { background: var(--h-acc) !important; color: var(--h-on-acc) !important; box-shadow: 0 4px 14px rgba($RA, 0.3) !important; }

/* ---- the player: a glass island floating at the bottom ---- */
.Root__now-playing-bar { background: transparent !important; padding: 0 !important; }
.main-nowPlayingBar-container, aside.main-nowPlayingBar-container {
  background: rgba($RS, 0.62) !important; backdrop-filter: blur(24px) saturate(1.3); border: 0 !important;
  border-radius: 22px !important; box-shadow: inset 0 0 0 1px var(--h-line2), 0 14px 40px rgba(0, 0, 0, 0.45) !important; margin: 0 !important; }
.main-nowPlayingWidget-coverArt, .main-nowPlayingWidget-coverArt img, .cover-art { border-radius: 10px !important; }
.main-nowPlayingWidget-nowPlaying .main-trackInfo-name { font-weight: 600; }
.player-controls__buttons button[data-testid="control-button-playpause"] { background: var(--h-acc) !important; color: var(--h-on-acc) !important;
  box-shadow: 0 0 0 4px rgba($RA, 0.18), 0 6px 18px rgba($RA, 0.35) !important; }
.player-controls__buttons button[data-testid="control-button-playpause"] svg { fill: var(--h-on-acc) !important; }
.main-shuffleButton-button.main-shuffleButton-enabled, .main-repeatButton-button.main-repeatButton-enabled,
.player-controls__buttons button[aria-checked="true"] { color: var(--h-acc) !important; }
/* the progress and volume bars: thin, an accent gradient that glows */
.x-progressBar-fillColor, .progress-bar__fg, .playback-bar .x-progressBar-fillColor { background: linear-gradient(90deg, var(--h-acc2), var(--h-acc)) !important;
  box-shadow: 0 0 10px rgba($RA, 0.45); }
.x-progressBar-progressBarBg, .progress-bar__bg { background: rgba($RF, 0.12) !important; }
.progress-bar__slider, .x-progressBar-sliderArea { background: var(--h-acc) !important; }
.x-progressBar-progressBarBg, .progress-bar { --progress-bar-height: 4px; --progress-bar-radius: 4px; }

/* ---- lyrics: dim lines, the sung one in the accent ---- */
:root { --lyrics-color-active: $fg !important; --lyrics-color-inactive: rgba($RF, 0.38) !important; --lyrics-color-passed: rgba($RF, 0.6) !important;
        --lyrics-color-background: transparent !important; --lyrics-color-messaging: $mut !important; }
.lyrics-lyrics-background, .lyrics-lyricsContainer-LyricsBackground { background: transparent !important; }
.lyrics-lyricsContent-active { color: var(--h-acc) !important; text-shadow: 0 0 24px rgba($RA, 0.45); }

/* ---- menus, tooltips, dialogs: glass ---- */
[role="menu"], .main-contextMenu-menu, .main-popupModal-container, .GenericModal {
  background: var(--h-glass-pop) !important; backdrop-filter: blur(22px) saturate(1.2); border-radius: 14px !important; border: 0 !important;
  box-shadow: inset 0 0 0 1px var(--h-line2), 0 16px 40px rgba(0, 0, 0, 0.5) !important; }
[role="menu"] { padding: 6px !important; }
.main-contextMenu-menuItemButton { border-radius: 8px !important; }
.main-contextMenu-menuItemButton:hover, .main-contextMenu-menuItemButton[aria-expanded="true"], .main-contextMenu-menuItemButton:focus {
  background: rgba($RA, 0.20) !important; }
.main-contextMenu-tippy, .tippy-box, [data-tippy-root] .main-contextMenu-tippy { background: transparent !important; }
.main-trackInfo-name a:hover, .main-trackInfo-artists a:hover, a:hover { text-decoration-color: var(--h-acc) !important; }

/* ---- scrollbars and selection ---- */
::-webkit-scrollbar { width: 6px !important; height: 6px !important; }
::-webkit-scrollbar-thumb { background: var(--h-line2) !important; border-radius: 8px !important; }
::-webkit-scrollbar-thumb:hover { background: rgba($RF, 0.28) !important; }
::-webkit-scrollbar-track { background: transparent !important; }
.os-scrollbar-handle { background: var(--h-line2) !important; }
::selection { background: rgba($RA, 0.35); }
$E
CSS
  } > "$u.tmp" && mv "$u.tmp" "$u"
  # theme.js (spicetify inject_theme_js): the cover of the song that plays, blurred behind the whole window. Nothing is sent anywhere:
  # it only reads the cover URL Spotify already has and sets one CSS variable.
  cat > "$d/theme.js.tmp" <<'JS'
// Halcyon (scripts/app-themes.sh): the cover of what plays, as --halcyon-cover, for the blurred sky behind the window. Rewritten: do not edit.
(function halcyonCover() {
  if (!window.Spicetify || !Spicetify.Player || !Spicetify.Player.addEventListener) { setTimeout(halcyonCover, 300); return }
  function url() {
    const m = Spicetify.Player.data && Spicetify.Player.data.item && Spicetify.Player.data.item.metadata
    const u = m && (m.image_xlarge_url || m.image_large_url || m.image_url)
    return u ? u.replace(/^spotify:image:/, "https://i.scdn.co/image/") : ""
  }
  function apply() {
    const u = url()
    document.documentElement.style.setProperty("--halcyon-cover", u ? 'url("' + u + '")' : "none")
  }
  Spicetify.Player.addEventListener("songchange", apply)
  apply()
})()
JS
  mv "$d/theme.js.tmp" "$d/theme.js"
}

spotify_apply() {   # a theme is only visible after `spicetify apply`; Spotify's UI restarts when it is open
  have spicetify || return 0
  local prefs="$HOME/.config/spotify/prefs"
  [ -f "$prefs" ] || { [ "$mode" = "--setup" ] && echo "   spicetify: start Spotify once and log in, then run  ~/.config/Halcyon/scripts/app-themes.sh --now"; return 0; }
  # -n = --no-restart: plain `spicetify apply` (re)starts Spotify, which is how it kept opening by itself after every
  # wallpaper change. Only the explicit --now / --setup runs may leave Spotify open; automatic runs never start it.
  spicetify apply -n >/dev/null 2>&1 || spicetify backup apply -n >/dev/null 2>&1
}
spotify_setup() {
  have spicetify || return 0
  spicetify >/dev/null 2>&1                                  # first run makes its config file
  # spotify-launcher keeps the client in your home: tell spicetify where
  [ -d "$SP_LAUNCHER" ] && spicetify config spotify_path "$SP_LAUNCHER" >/dev/null 2>&1
  [ -f "$HOME/.config/spotify/prefs" ] && spicetify config prefs_path "$HOME/.config/spotify/prefs" >/dev/null 2>&1
  spicetify config current_theme halcyon color_scheme base inject_css 1 inject_theme_js 1 replace_colors 1 overwrite_assets 1 >/dev/null 2>&1
}

# ================================================================== Discord (Vesktop / Vencord)
discord_theme() {
  local base
  app_tones
  mixv "$bg" "$fg" 7; local hov=$MIX
  mixv "$bg" "$fg" 12; local hov2=$MIX
  local RF RA RA2 RB RS RBASE
  RF=$(rgb "$fg"); RA=$(rgb "$acc"); RA2=$(rgb "$acc2"); RB=$(rgb "$bg"); RS=$(rgb "$surf"); RBASE=$(rgb "$T_BASE")
  for base in "$HOME/.config/vesktop" "$HOME/.config/Vencord"; do
    [ -d "$base" ] || { [ "$base" = "$HOME/.config/vesktop" ] && have vesktop && mkdir -p "$base" || continue; }
    mkdir -p "$base/themes"
    cat > "$base/themes/halcyon.theme.css.tmp" <<CSS
/**
 * @name Halcyon
 * @description The Halcyon rice in Discord: floating glass panels over a quiet starfield, in your wallpaper's colours. Written by scripts/app-themes.sh (rewritten on every wallpaper change: do not edit).
 * @version 3
 */
/* Layout: the deepest layer is a dark sky (a few faint stars and an accent glow in the corners); the channel list and the main view
   float on it as rounded glass cards, the user panel is a glass pill, the message box a glass bar that glows while you type.
   The accent is only for what is selected, unread, a link or a primary button. Icons and avatars keep their shapes.
   Discord renames class suffixes now and then: rules match the stable prefix, and a rule that stops matching is harmless. */
:root, .theme-dark, .theme-darker, .theme-light, .theme-midnight, .visual-refresh {
  --h-base: $T_BASE; --h-side: $T_SIDE; --h-bg: $bg; --h-surf: $surf; --h-hov: $hov; --h-hov2: $hov2; --h-fg: $fg; --h-mut: $mut;
  --h-acc: $acc; --h-acc2: $acc2; --h-on-acc: $ON_ACC; --h-red: $red; --h-green: $green; --h-yellow: $yellow;
  --h-line: $T_LINE; --h-line2: $T_LINE2; --h-glass: rgba($RB, 0.74); --h-glass-side: rgba($RB, 0.62); --h-glass-pop: rgba($RS, 0.90);
  --h-glow: 0 0 0 1px rgba($RA, 0.55), 0 0 22px rgba($RA, 0.22);
  --h-shadow: 0 10px 30px rgba(0, 0, 0, 0.35);
  --font-primary: "Inter", "gg sans", "Noto Sans", sans-serif; --font-display: "Inter Display", "Inter", "gg sans", sans-serif;
  /* surfaces (older names: primary = chat, secondary = channel list, tertiary = server rail; newer: base-*, surface-*, bg-*) */
  --background-primary: transparent !important; --background-secondary: transparent !important; --background-secondary-alt: transparent !important;
  --background-tertiary: transparent !important; --background-base-low: transparent !important; --background-base-lower: transparent !important;
  --background-base-lowest: transparent !important; --chat-background: transparent !important; --chat-background-default: transparent !important;
  --app-frame-background: transparent !important; --app-frame-border: transparent !important; --bg-base-primary: transparent !important;
  --bg-base-secondary: transparent !important; --bg-base-tertiary: transparent !important;
  --background-floating: var(--h-glass-pop) !important; --background-surface-high: var(--h-surf) !important;
  --background-surface-higher: var(--h-hov) !important; --background-surface-highest: var(--h-hov2) !important; --bg-surface-raised: var(--h-surf) !important;
  --background-accent: var(--h-hov2) !important; --card-background-default: var(--h-surf) !important; --card-secondary-bg: var(--h-hov) !important;
  --channeltextarea-background: transparent !important; --input-background: var(--h-surf) !important;
  --modal-background: var(--h-glass-pop) !important; --modal-footer-background: rgba($RBASE, 0.5) !important;
  --background-modifier-hover: $T_HOVER !important; --background-modifier-selected: $T_SEL !important;
  --background-modifier-active: $T_SEL2 !important; --background-modifier-accent: var(--h-line) !important;
  --border-subtle: var(--h-line) !important; --border-normal: var(--h-line2) !important; --border-muted: var(--h-line) !important;
  --border-focus: var(--h-acc) !important;
  /* text and icons */
  --text-normal: var(--h-fg) !important; --text-default: var(--h-fg) !important; --text-strong: var(--h-fg) !important;
  --text-muted: var(--h-mut) !important; --text-subtle: var(--h-mut) !important; --chat-text-muted: var(--h-mut) !important;
  --header-primary: var(--h-fg) !important; --header-secondary: var(--h-mut) !important;
  --interactive-normal: var(--h-mut) !important; --interactive-hover: var(--h-fg) !important; --interactive-active: var(--h-fg) !important;
  --interactive-muted: var(--h-line2) !important; --interactive-text-default: var(--h-mut) !important; --interactive-text-hover: var(--h-fg) !important;
  --interactive-text-active: var(--h-fg) !important; --icon-default: var(--h-mut) !important; --icon-strong: var(--h-fg) !important;
  --channels-default: var(--h-mut) !important; --channel-icon: var(--h-mut) !important;
  --text-link: var(--h-acc) !important; --text-brand: var(--h-acc) !important;
  /* the accent: old brand names and the newer control-* buttons */
  --brand-experiment: var(--h-acc) !important; --brand-500: var(--h-acc) !important; --brand-560: var(--h-acc) !important; --brand-360: var(--h-acc) !important;
  --brand-experiment-560: var(--h-acc) !important; --brand-experiment-600: var(--h-acc) !important; --background-brand: var(--h-acc) !important;
  --button-filled-brand-background: var(--h-acc) !important; --button-filled-brand-text: var(--h-on-acc) !important;
  --control-brand-foreground: var(--h-acc) !important; --control-brand-foreground-new: var(--h-acc) !important;
  --control-primary-background-default: var(--h-acc) !important; --control-primary-background-hover: color-mix(in srgb, var(--h-acc) 88%, white) !important;
  --control-primary-background-active: color-mix(in srgb, var(--h-acc) 80%, black) !important;
  --control-primary-border-default: transparent !important; --control-primary-border-hover: transparent !important; --control-primary-border-active: transparent !important;
  --control-primary-text-default: var(--h-on-acc) !important; --control-primary-text-hover: var(--h-on-acc) !important; --control-primary-text-active: var(--h-on-acc) !important;
  --control-primary-icon-default: var(--h-on-acc) !important; --control-primary-icon-hover: var(--h-on-acc) !important; --control-primary-icon-active: var(--h-on-acc) !important;
  --control-secondary-background-default: var(--h-hov) !important; --control-secondary-background-hover: var(--h-hov2) !important;
  --control-secondary-background-active: var(--h-hov2) !important; --control-secondary-text-default: var(--h-fg) !important;
  --control-secondary-border-default: var(--h-line) !important; --control-secondary-border-hover: var(--h-line2) !important;
  --mention-foreground: var(--h-acc) !important; --mention-background: $T_SEL !important;
  --status-positive: var(--h-green) !important; --status-warning: var(--h-yellow) !important; --status-danger: var(--h-red) !important;
  --status-positive-background: var(--h-green) !important; --status-danger-background: var(--h-red) !important;
  --scrollbar-thin-thumb: var(--h-line2) !important; --scrollbar-auto-thumb: var(--h-line2) !important; --scrollbar-auto-track: transparent !important;
  --button-border-radius: 10px; --radius-sm: 8px; --radius-md: 12px; --radius-lg: 16px;
}

/* ---- the sky behind everything ---- */
[class^="appMount_"], [class^="app_"], [class*=" app_"], [class^="bg_"], [class*=" bg_"] {
  background:
    radial-gradient(1px 1px at 8% 14%, rgba($RF, 0.55), transparent 60%), radial-gradient(1px 1px at 23% 71%, rgba($RF, 0.35), transparent 60%),
    radial-gradient(1.5px 1.5px at 41% 33%, rgba($RF, 0.45), transparent 60%), radial-gradient(1px 1px at 57% 88%, rgba($RF, 0.30), transparent 60%),
    radial-gradient(1px 1px at 68% 9%, rgba($RF, 0.50), transparent 60%), radial-gradient(1.5px 1.5px at 79% 57%, rgba($RA, 0.55), transparent 60%),
    radial-gradient(1px 1px at 91% 26%, rgba($RF, 0.40), transparent 60%), radial-gradient(1px 1px at 4% 92%, rgba($RA2, 0.45), transparent 60%),
    radial-gradient(1px 1px at 35% 6%, rgba($RF, 0.30), transparent 60%), radial-gradient(1.5px 1.5px at 96% 81%, rgba($RF, 0.35), transparent 60%),
    radial-gradient(ellipse 60% 45% at 100% 0%, rgba($RA, 0.14), transparent 70%),
    radial-gradient(ellipse 55% 50% at 0% 100%, rgba($RA2, 0.10), transparent 70%),
    var(--h-base) !important;
}
[class^="bar_"], [class*=" bar_"][class*="theme-"] { background: transparent !important; }
[class^="bar_"] [class^="title_"] { color: var(--h-mut) !important; font-weight: 500; letter-spacing: .02em; }

/* ---- floating glass cards: the channel list and the main view ---- */
[class^="sidebarList_"], [class^="page_"] {
  background: var(--h-glass) !important; backdrop-filter: blur(16px) saturate(1.1);
  border-radius: 16px !important; overflow: hidden !important;
  box-shadow: inset 0 0 0 1px var(--h-line), var(--h-shadow) !important;
}
[class^="sidebarList_"] { background: var(--h-glass-side) !important; margin: 0 8px 76px 0 !important; }
[class^="page_"] { margin: 0 8px 8px 0 !important; }
[class^="page_"] main, [class^="page_"] [class^="chat_"], [class^="chatContent_"], [class^="tabBody_"], [class^="nowPlayingColumn_"],
[class^="privateChannels_"], [class*="guilds_"] [class^="scroller_"], nav[class*="container_"][class*="guild"], [class^="container_"][class*="themed_"],
[class^="members_"], [class^="membersWrap_"], [class^="member_"], [class^="container_"][class*="threadSidebar"] { background: transparent !important; }
[class^="page_"] section[class*="title_"], [class^="page_"] section[class*="themed_"] { background: transparent !important; box-shadow: 0 1px 0 var(--h-line) !important; border: 0 !important; }
[class^="sidebarList_"] [class^="searchBar_"] { background: transparent !important; box-shadow: 0 1px 0 var(--h-line) !important; }
[class^="sidebarList_"] [class^="searchBar_"] button { border-radius: 10px !important; background: var(--h-hov) !important; }

/* ---- the user panel: a glass pill under both rails ---- */
[class^="panels_"] {
  background: rgba($RS, 0.72) !important; backdrop-filter: blur(18px) saturate(1.2);
  border-radius: 18px !important; box-shadow: inset 0 0 0 1px var(--h-line2), var(--h-shadow) !important; border: 0 !important;
}

/* ---- server rail ---- */
[class*="guilds_"] [class*="blobContainer_"][class*="selected_"] { filter: drop-shadow(0 0 6px rgba($RA, 0.55)); }
[class*="guilds_"] [class*="pill_"] span, [class*="guilds_"] [class*="item_"][class*="selected"] { background: var(--h-acc) !important; }
[class*="guilds_"] [class*="numberBadge_"], [class*="numberBadge_"] { background-color: var(--h-acc) !important; color: var(--h-on-acc) !important; font-weight: 700; }
[class*="guildSeparator_"] { background: var(--h-line2) !important; }

/* ---- channel and DM rows: a wash on hover, an accent edge when selected ---- */
[class*="containerDefault_"] [class*="wrapper_"], li[class*="channel_"] [class*="interactive_"] { border-radius: 10px !important; transition: background .15s ease; }
[class*="containerDefault_"] [class*="wrapper_"]:hover, li[class*="channel_"] [class*="interactive_"]:hover { background: var(--h-hov) !important; }
[class*="modeSelected_"], [class*="interactiveSelected_"], li[class*="selected_"] [class*="interactive_"], [class*="containerDefault_"][class*="selected_"] [class*="link_"] {
  background: linear-gradient(90deg, rgba($RA, 0.22), rgba($RA, 0.06)) !important; box-shadow: inset 2px 0 0 var(--h-acc) !important; border-radius: 10px !important; }
[class*="modeSelected_"] [class*="name_"], li[class*="selected_"] [class*="name_"], [class*="interactiveSelected_"] [class*="name_"] { color: var(--h-fg) !important; }
[class*="modeUnread_"] [class*="name_"] { color: var(--h-fg) !important; font-weight: 600; }
[class*="unread_"][class*="unreadImportant"], [class*="unread_"] { background: var(--h-acc) !important; }

/* ---- messages ---- */
[class*="messageListItem_"] [class*="message_"], [class*="cozyMessage_"] { border-radius: 10px; margin: 0 8px; }
[class*="messageListItem_"] [class*="message_"]:hover, [class*="cozyMessage_"]:hover { background: var(--h-hov) !important; }
[class*="mentioned_"] { background: linear-gradient(90deg, rgba($RA2, 0.16), transparent 70%) !important; box-shadow: inset 2px 0 0 var(--h-acc2) !important; }
[class*="mentioned_"]:hover { background: linear-gradient(90deg, rgba($RA2, 0.24), transparent 75%) !important; }
[class*="mention"][class*="interactive"], .mention { background: rgba($RA, 0.18) !important; color: var(--h-acc) !important; border-radius: 6px; }
[class*="newMessagesBar_"] { background: var(--h-acc) !important; color: var(--h-on-acc) !important; border-radius: 0 0 12px 12px; }
[class*="divider_"][class*="isUnread"] { border-color: var(--h-acc) !important; }
[class*="divider_"][class*="isUnread"] [class*="unreadPill_"] { background: var(--h-acc) !important; color: var(--h-on-acc) !important; }
[class*="markup_"] code, [class*="markup_"] pre, [class*="codeBlockText"] { background: rgba($RBASE, 0.6) !important; box-shadow: inset 0 0 0 1px var(--h-line) !important; border: 0 !important; border-radius: 10px !important; }
[class*="embedFull_"], [class*="embedWrapper_"] { background: rgba($RS, 0.6) !important; border-radius: 12px !important; border-left-color: var(--h-acc) !important; box-shadow: inset 0 0 0 1px var(--h-line); }
[class*="reaction_"] { background: var(--h-hov) !important; border-radius: 10px !important; box-shadow: inset 0 0 0 1px var(--h-line) !important; }
[class*="reaction_"][class*="reactionMe"] { background: rgba($RA, 0.18) !important; box-shadow: inset 0 0 0 1px rgba($RA, 0.6) !important; }

/* ---- the message box: a glass bar that glows while you type ---- */
[class*="channelTextArea_"] [class*="scrollableContainer_"], [class*="channelTextArea_"][class*="channelTextArea"] > div {
  background: rgba($RS, 0.70) !important; backdrop-filter: blur(14px); border-radius: 16px !important; box-shadow: inset 0 0 0 1px var(--h-line2) !important; }
[class*="channelTextArea_"]:focus-within [class*="scrollableContainer_"] { box-shadow: var(--h-glow) !important; }
[class*="channelTextArea_"] { background: transparent !important; }
[class^="form_"] [class*="typing_"] { color: var(--h-acc) !important; }

/* ---- buttons ---- */
button[class*="button_"] { border-radius: 10px !important; }
button[class*="primary_"], [class*="lookFilled_"][class*="colorBrand_"] { box-shadow: 0 4px 14px rgba($RA, 0.25); font-weight: 600; }
button[class*="primary_"]:hover, [class*="lookFilled_"][class*="colorBrand_"]:hover { box-shadow: 0 6px 20px rgba($RA, 0.35); }
[class*="notice_"][class*="colorDefault"], [class*="notice_"] { background: linear-gradient(90deg, rgba($RA, 0.85), rgba($RA2, 0.85)) !important; color: var(--h-on-acc) !important; }

/* ---- menus, pop-outs, tooltips, the quick switcher and dialogs: glass ---- */
[class*="layer_"] [class*="menu_"], [class*="popout_"], [class*="quickswitcher_"], [class*="userPopoutOuter_"], [class*="autocomplete_"] {
  background: var(--h-glass-pop) !important; backdrop-filter: blur(22px) saturate(1.2); border: 0 !important; border-radius: 14px !important;
  box-shadow: inset 0 0 0 1px var(--h-line2), 0 16px 40px rgba(0, 0, 0, 0.5) !important; }
[class*="menu_"] [class*="item_"] { border-radius: 8px !important; }
[class*="item_"][class*="focused"] { background: rgba($RA, 0.20) !important; color: var(--h-fg) !important; }
[class*="tooltip_"] { background: var(--h-surf) !important; color: var(--h-fg) !important; border-radius: 10px !important; box-shadow: inset 0 0 0 1px var(--h-line2), 0 8px 20px rgba(0,0,0,.4) !important; }
[class*="tooltipPointer_"] { border-top-color: var(--h-surf) !important; }
[class*="root_"][class*="modal"], [class*="modal_"], [class*="focusLock_"] [role="dialog"] { border-radius: 18px !important; overflow: hidden; }
[class*="backdrop_"] { background: rgba($RBASE, 0.7) !important; backdrop-filter: blur(6px); }

/* ---- user settings: the same glass ---- */
[class*="standardSidebarView_"] { background: transparent !important; }
[class*="standardSidebarView_"] [class*="sidebarRegionScroller_"] { background: var(--h-glass-side) !important; }
[class*="standardSidebarView_"] [class*="contentRegion_"] { background: var(--h-glass) !important; }
[class*="side_"] [class*="item_"][class*="selected_"] { background: rgba($RA, 0.20) !important; color: var(--h-fg) !important; box-shadow: inset 2px 0 0 var(--h-acc); }

/* ---- scrollbars and selection ---- */
[class*="scroller_"]::-webkit-scrollbar { width: 6px !important; height: 6px !important; }
[class*="scroller_"]::-webkit-scrollbar-thumb { background: var(--h-line2) !important; border-radius: 8px !important; border: 0 !important; }
[class*="scroller_"]::-webkit-scrollbar-thumb:hover { background: rgba($RF, 0.28) !important; }
[class*="scroller_"]::-webkit-scrollbar-track { background: transparent !important; border: none !important; }
::selection { background: rgba($RA, 0.35); }
CSS
    mv "$base/themes/halcyon.theme.css.tmp" "$base/themes/halcyon.theme.css"
    # Vesktop's own settings: the loading splash wears the same colours
    if [ "$base" = "$HOME/.config/vesktop" ] && command -v jq >/dev/null 2>&1; then
      local vs="$base/settings.json"; [ -s "$vs" ] || echo '{}' > "$vs"
      jq --arg bg "$bg" --arg fg "$fg" '.splashTheming = true | .splashBackground = $bg | .splashColor = $fg' "$vs" > "$vs.new" 2>/dev/null && mv "$vs.new" "$vs"
    fi
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
  # micro: "colorscheme": "halcyon" in settings.json (the old file is kept once as settings.json.before-halcyon)
  if have micro; then
    f="$HOME/.config/micro/settings.json"; mkdir -p "$(dirname "$f")"
    if [ ! -s "$f" ] || [ "$(tr -d ' \n\t\r' < "$f")" = "{}" ]; then echo '{"colorscheme": "halcyon"}' > "$f"
    elif ! grep -q '"colorscheme" *: *"halcyon"' "$f"; then
      [ -e "$f.before-halcyon" ] || cp -p "$f" "$f.before-halcyon"
      if grep -q '"colorscheme"' "$f"; then sed -i 's|"colorscheme" *: *"[^"]*"|"colorscheme": "halcyon"|' "$f"
      else sed -i '0,/{/s|{|{\n    "colorscheme": "halcyon",|' "$f"; fi
    fi
    echo "   micro: colorscheme halcyon (transparent)"
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
  # spotify-player: theme = "halcyon" in app.toml (a top-level key: it has to stay above any [table])
  if have spotify_player; then
    f="$HOME/.config/spotify-player/app.toml"; mkdir -p "$(dirname "$f")"
    if [ ! -f "$f" ]; then echo 'theme = "halcyon"' > "$f"
    elif ! grep -q '^theme *= *"halcyon"' "$f"; then
      [ -e "$f.before-halcyon" ] || cp -p "$f" "$f.before-halcyon"
      if grep -q '^theme *=' "$f"; then sed -i 's|^theme *=.*|theme = "halcyon"|' "$f"; else sed -i '1i theme = "halcyon"' "$f"; fi
    fi
    echo "   spotify-player: theme halcyon"
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

# editors, browsers, Qt apps (the apps you chose in the installer): see scripts/app-themes-extra.sh
[ -f "$here/app-themes-extra.sh" ] && . "$here/app-themes-extra.sh"

# every run: pick the halcyon theme where an app still has another one (existing choices are backed up once), then write the files
[ "$mode" = "--setup" ] && starship_choice
starship_adopt
starship_sysmode_migrate
starship_sysmode_sync
starship_theme; fish_theme; btop_theme; micro_theme; yazi_theme; spotify_player_theme; spotify_theme; discord_theme
if declare -F editors_theme >/dev/null; then editors_theme; browser_theme; qt_theme; fi
ensure_choices >/dev/null          # after the files exist (Vesktop needs its theme file first)
have btop && pkill -USR2 -x btop 2>/dev/null     # a running btop re-reads its config and theme
if [ "$mode" = "--setup" ]; then ensure_choices; spotify_setup; fi
if [ "$mode" = "--now" ] || [ "$mode" = "--setup" ]; then spotify_apply
elif ! pgrep -x spotify >/dev/null 2>&1; then spotify_apply; fi    # --auto: only while Spotify is closed (applying restarts its UI)
log "$mode done"
exit 0
