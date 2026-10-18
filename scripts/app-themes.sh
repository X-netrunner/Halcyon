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
  # user.css: the Halcyon shape (floating rounded panels, soft cards, pill buttons). Only the marked block is rewritten: your own CSS below it stays.
  local B="/* >>> halcyon >>> */" E="/* <<< halcyon <<< */" u="$d/user.css"
  mixv "$bg" "$acc" 14; local sel=$MIX
  {
    strip_block "$u" "$B" "$E"
    cat <<CSS
$B
/* written by scripts/app-themes.sh: do not edit this block (Spotify renames classes now and then: a rule that stops matching is harmless) */
.Root__top-container { gap: 8px !important; padding: 8px !important; background: $bg !important; }
.Root__nav-bar, .Root__main-view, .Root__right-sidebar, .Root__now-playing-bar, .main-yourLibraryX-libraryContainer, .main-view-container {
  border-radius: 16px !important; }
.Root__nav-bar, .Root__right-sidebar { background: $surf !important; border: 1px solid $hi !important; }
.Root__main-view { background: $bg !important; border: 1px solid $hi !important; overflow: hidden !important; }
.main-nowPlayingBar-container, .Root__now-playing-bar { background: $surf !important; border: 1px solid $hi !important; border-radius: 16px !important; }
.main-topBar-background, .main-topBar-container { background: transparent !important; }
.main-entityHeader-background { background: linear-gradient(180deg, $sel, $bg) !important; }
.main-home-content, .main-entityHeader-container { background: transparent !important; }
.main-card-card, .main-cardImage-imageWrapper { border-radius: 14px !important; }
.main-card-card { background: $surf !important; border: 1px solid transparent !important; transition: background .15s ease, border-color .15s ease, transform .15s ease !important; }
.main-card-card:hover { background: $hi !important; border-color: $acc !important; transform: translateY(-2px); }
.main-trackList-trackListRow { border-radius: 10px !important; }
.main-trackList-trackListRow:hover { background: rgba($(rgb "$acc"), 0.12) !important; }
.main-trackList-selected, .main-trackList-active { background: rgba($(rgb "$acc"), 0.22) !important; }
.main-trackList-playingIcon, .main-trackList-rowPlayPauseButton { color: $acc !important; }
.main-playButton-PlayButton, .main-playPauseButton-button { background: $acc !important; color: $bg !important; border-radius: 50% !important; }
.main-playButton-PlayButton:hover { filter: brightness(1.12); transform: scale(1.05) !important; }
.main-shuffleButton-button.main-shuffleButton-enabled, .main-repeatButton-button.main-repeatButton-enabled { color: $acc !important; }
.main-globalNav-searchContainer input, .x-searchInput-searchInputInput, .main-topBar-searchBar input { background: $surf !important; border: 1px solid $hi !important; border-radius: 12px !important; }
.x-searchInput-searchInputInput:focus, .main-globalNav-searchContainer input:focus { border-color: $acc !important; }
.main-yourLibraryX-listItem a, .main-yourLibraryX-libraryItemContainer, .main-yourLibraryX-listRow { border-radius: 10px !important; }
.main-yourLibraryX-listItem:hover, .main-yourLibraryX-libraryItemContainer:hover { background: rgba($(rgb "$acc"), 0.10) !important; }
.progress-bar__slider, .x-progressBar-fillColor { background: $acc !important; }
.main-actionButtons button, .main-buttons-button { border-radius: 999px !important; }
[role="menu"], .main-contextMenu-menu, .main-contextMenu-menuItem { background: $surf !important; border-radius: 12px !important; }
.main-contextMenu-menu { border: 1px solid $hi !important; box-shadow: 0 10px 30px rgba(0,0,0,.4) !important; padding: 6px !important; }
.main-contextMenu-menuItemButton:hover { background: rgba($(rgb "$acc"), 0.18) !important; border-radius: 8px !important; }
::-webkit-scrollbar { width: 8px !important; }
::-webkit-scrollbar-thumb { background: $hi !important; border-radius: 8px !important; }
::-webkit-scrollbar-thumb:hover { background: $acc !important; }
::-webkit-scrollbar-track { background: transparent !important; }
::selection { background: rgba($(rgb "$acc"), 0.35); }
$E
CSS
  } > "$u.tmp" && mv "$u.tmp" "$u"
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
  --radius-sm: 8px; --radius-md: 12px; --radius-lg: 16px;
  --custom-guild-icon-border-radius: 14px;
  --font-primary: "Inter", "gg sans", sans-serif;
}
/* ---- shape: the same soft cards as the island (class names are matched by their stable prefix, Discord renames the suffix) ---- */
[class*="guilds_"] { background: var(--h-bg) !important; }
[class*="sidebar_"] { background: var(--h-surf) !important; border-radius: 16px 0 0 0; border-top: 1px solid var(--h-hi); border-left: 1px solid var(--h-hi); }
[class*="chat_"] { background: var(--h-bg) !important; }
[class*="chatContent_"] { background: var(--h-bg) !important; }
[class*="title_"][class*="container_"], [class*="bar_"][class*="themed_"] { background: var(--h-bg) !important; box-shadow: none !important; border-bottom: 1px solid var(--h-hi) !important; }
[class*="members_"], [class*="membersWrap_"] { background: var(--h-surf) !important; }
[class*="panels_"] { background: var(--h-bg) !important; border-top: 1px solid var(--h-hi) !important; }
[class*="channelTextArea_"], [class*="textArea_"] { background: var(--h-surf) !important; border-radius: 14px !important; border: 1px solid var(--h-hi) !important; }
[class*="channelTextArea_"]:focus-within { border-color: var(--h-acc) !important; box-shadow: 0 0 0 1px var(--h-acc) !important; }
[class*="searchBar_"] { background: var(--h-surf) !important; border-radius: 10px !important; }
[class*="wrapper_"][class*="guildIcon"], [class*="icon_"][class*="guild"], [class*="listItem_"] [class*="wrapper_"] > svg { transition: border-radius .15s ease; }
[class*="selected_"][class*="wrapper_"] > [class*="pill"], [class*="item_"][class*="selected"] { background: var(--h-acc) !important; }
[class*="containerDefault_"] [class*="wrapper_"][class*="selected"], [class*="modeSelected"] { background: rgba($(rgb "$acc"), 0.18) !important; border-radius: 10px !important; }
[class*="containerDefault_"] [class*="wrapper_"]:hover, [class*="modeUnread"]:hover { background: rgba($(rgb "$acc"), 0.10) !important; border-radius: 10px !important; }
[class*="messageListItem_"] [class*="message_"]:hover, [class*="cozyMessage_"]:hover { background: rgba($(rgb "$hov"), 0.55) !important; border-radius: 10px; }
[class*="mentioned_"] { background: rgba($(rgb "$acc"), 0.10) !important; box-shadow: inset 2px 0 0 var(--h-acc) !important; }
[class*="mentioned_"]:hover { background: rgba($(rgb "$acc"), 0.16) !important; }
[class*="newMessagesBar_"], [class*="divider_"][class*="isUnread"] { color: var(--h-acc) !important; border-color: var(--h-acc) !important; }
[class*="layer_"] [class*="menu_"], [class*="popout_"], [class*="quickswitcher_"], [class*="container_"][class*="menu"] { background: var(--h-surf) !important; border: 1px solid var(--h-hi) !important; border-radius: 14px !important; box-shadow: 0 10px 30px rgba(0,0,0,.4) !important; }
[class*="item_"][class*="focused"] { background: rgba($(rgb "$acc"), 0.22) !important; border-radius: 8px; }
[class*="root_"][class*="modal"], [class*="modal_"] { border-radius: 18px !important; border: 1px solid var(--h-hi) !important; }
[class*="markup_"] code, [class*="markup_"] pre, [class*="codeBlockText"] { background: var(--h-surf) !important; border: 1px solid var(--h-hi) !important; border-radius: 10px !important; }
[class*="embedWrapper_"] { background: var(--h-surf) !important; border-color: var(--h-hi) !important; border-radius: 12px !important; }
[class*="lookFilled_"][class*="colorBrand_"] { border-radius: 10px !important; font-weight: 600; }
[class*="avatar_"] img, [class*="avatar_"] svg { border-radius: 50% !important; }
[class*="scroller_"]::-webkit-scrollbar { width: 8px !important; height: 8px !important; }
[class*="scroller_"]::-webkit-scrollbar-thumb { background: var(--h-hi) !important; border-radius: 8px !important; border: 2px solid transparent !important; background-clip: padding-box !important; }
[class*="scroller_"]::-webkit-scrollbar-thumb:hover { background: var(--h-acc) !important; background-clip: padding-box !important; }
[class*="scroller_"]::-webkit-scrollbar-track { background: transparent !important; border: none !important; }
::selection { background: rgba($(rgb "$acc"), 0.35); }
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
