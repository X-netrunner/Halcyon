#!/usr/bin/env bash
# shellcheck disable=SC2088   # the "~" in messages is meant literally
# Per-user setup steps that install.sh runs AS YOUR USER (never as root, so nothing in your home ends up owned by root).
# Safe to run by hand any time:
#     user-setup.sh hypr-entry            ~/.config/hypr/hyprland.lua loads Halcyon (your old Hyprland config is backed up first)
#     user-setup.sh login-add             the start-on-tty1 lines in ~/.bash_profile / ~/.zprofile (lock screen as login screen)
#     user-setup.sh login-remove          take those lines out again
#     user-setup.sh tty-autostart         start Halcyon on tty1 without the lock screen first
#     user-setup.sh wallpaper             make a first wallpaper if the folder is empty, then colours from a wallpaper
#     user-setup.sh terminals             colour files + the Halcyon look (fish, font, padding, 0.85 alpha, cursor, scrollback, search keys) for
#                                         foot / kitty / alacritty / ghostty / wezterm, included once
#     user-setup.sh app-themes            Starship prompt (with the rice name) + fish colours, then the halcyon theme for btop / yazi /
#                                         Spotify (spicetify) / Discord (Vesktop); all follow the wallpaper (scripts/app-themes.sh)
#     user-setup.sh default-apps [browser=ID] [files=ID] [editor=ID]
#                                         foot / Thunar / Spotify / Discord become the default terminal / files / music / chat
#                                         (only for a kind you have not chosen yourself in Settings > Default apps).
#                                         browser= / files= / editor= are what you picked in the installer: those always win
#     user-setup.sh save-choices K=V...   remember the installer's picks (~/.local/state/island/install-choices.env: BROWSER FILES EDITOR SYSMODE SAFETY_CHECK)
#     user-setup.sh gpu-env MODE          ~/.config/Halcyon/gpu.lua for this GPU setup: nvidia | hybrid | none
# Exit status: 0 = done / nothing to do, 1 = could not do it (a message says why).
set -uo pipefail

RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
BIN="$RICE/bin"
STAMP="${HALCYON_STAMP:-$(date +%Y%m%d-%H%M%S)}"
ME="$(id -un)"
SNIP_MARK="# Halcyon: on tty1 start the desktop with the lock screen as the login screen"

ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------------------------- Hyprland loads Halcyon
hypr_entry() {
  mkdir -p "$HOME/.config/hypr"
  local hl="$HOME/.config/hypr/hyprland.lua" f
  local stub='-- Halcyon: loads the whole rice from ~/.config/Halcyon (written by install.sh)
dofile(os.getenv("HOME") .. "/.config/Halcyon/hyprland.lua")'
  if [ -f "$hl" ] && grep -q "Halcyon/hyprland.lua" "$hl"; then ok "~/.config/hypr/hyprland.lua already points at Halcyon"; return 0; fi
  if [ -e "$hl" ] || [ -e "$HOME/.config/hypr/hyprland.conf" ]; then
    mkdir -p "$HOME/.config/hypr/backup-$STAMP"
    for f in hyprland.lua hyprland.conf; do
      [ -e "$HOME/.config/hypr/$f" ] && mv "$HOME/.config/hypr/$f" "$HOME/.config/hypr/backup-$STAMP/$f"
    done
    ok "your old Hyprland config is in ~/.config/hypr/backup-$STAMP"
  fi
  printf '%s\n' "$stub" > "$hl" && ok "~/.config/hypr/hyprland.lua now loads Halcyon"
}

# ---------------------------------------------------------------------------------------------- start on tty1
login_profile() {   # the profile file of the shell tty1 will run (bash or zsh); empty = unsupported shell
  local sh; sh=$(basename "$(getent passwd "$ME" | cut -d: -f7)")
  case "$sh" in bash) echo "$HOME/.bash_profile" ;; zsh) echo "${ZDOTDIR:-$HOME}/.zprofile" ;; esac
}
login_fish_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/halcyon-login.fish"; }
login_is_fish() { [ "$(basename "$(getent passwd "$ME" | cut -d: -f7)")" = fish ]; }
login_add_fish() {   # fish has no ~/.bash_profile: its own conf.d file (runs for every fish, the snippet only acts in the tty1 login shell)
  local f; f=$(login_fish_file); mkdir -p "$(dirname "$f")"
  cat > "$f" <<FISH
$SNIP_MARK (install.sh; undo with ./install.sh --remove-lock-login)
if status is-login; and test -z "\$WAYLAND_DISPLAY"; and test -z "\$DISPLAY"; and test (tty) = /dev/tty1; and not test -e "\$HOME/.cache/island/no-autostart"
    exec "$RICE/launch/halcyon-login.sh"
end
FISH
  grep -q "halcyon-login.sh" "$f" 2>/dev/null
}
login_add() {   # 0 = the lines are in place
  if login_is_fish; then login_add_fish; return; fi
  local f; f=$(login_profile); [ -n "$f" ] || return 1
  if ! grep -q "halcyon-login.sh" "$f" 2>/dev/null; then
    # an older --tty-autostart line would start Halcyon WITHOUT the lock first: replace it
    [ -f "$f" ] && sed -i '/# Halcyon: start the desktop on tty1/,+1d' "$f"
    if [ ! -f "$f" ]; then   # a new .bash_profile hides ~/.profile and ~/.bashrc: keep loading them
      : > "$f"
      if [ "$(basename "$f")" = .bash_profile ]; then
        { [ -f "$HOME/.profile" ] && echo '[ -f ~/.profile ] && . ~/.profile'; echo '[ -f ~/.bashrc ] && . ~/.bashrc'; } >> "$f"
      fi
    fi
    printf '\n%s (install.sh; undo with ./install.sh --remove-lock-login)\nif [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ] && [ ! -e "$HOME/.cache/island/no-autostart" ]; then\n  exec "%s/launch/halcyon-login.sh"\nfi\n' "$SNIP_MARK" "$RICE" >> "$f"
  fi
  grep -q "halcyon-login.sh" "$f" 2>/dev/null
}
login_remove() {
  local f
  rm -f "$(login_fish_file)"
  for f in "$HOME/.bash_profile" "${ZDOTDIR:-$HOME}/.zprofile"; do
    [ -f "$f" ] && sed -i "/$SNIP_MARK/,/^fi\$/d" "$f"
  done
}
tty_autostart() {
  local p="$HOME/.bash_profile"
  grep -q "halcyon.sh" "$p" 2>/dev/null && return 0
  printf '\n# Halcyon: start the desktop on tty1\nif [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then exec %s/launch/halcyon.sh; fi\n' "$RICE" >> "$p" \
    && ok "tty1 now starts Halcyon on login (~/.bash_profile)"
}

# ---------------------------------------------------------------------------------------------- wallpaper + colours
wallpaper() {
  local wp="$HOME/Pictures/Wallpapers" im first
  mkdir -p "$wp"
  find_first() { find "$wp" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | head -n1; }
  if [ -z "$(find_first)" ]; then
    if command -v magick >/dev/null || command -v convert >/dev/null; then
      im=magick; command -v magick >/dev/null || im=convert
      if $im -size 2560x1600 gradient:'#1b2340-#6a4c93' -rotate 15 -gravity center -crop 2560x1600+0+0 +repage "$wp/halcyon-default.png" 2>/dev/null; then
        ok "no wallpapers found: made a first one ($wp/halcyon-default.png). Put your own pictures in $wp; Settings > Wallpaper picks a new one."
      fi
    else warn "no wallpapers in $wp and ImageMagick is missing"; fi
  fi
  first=$(find_first)
  if [ -n "$first" ]; then
    # palette.sh takes the wallpaper's own colours (needs ImageMagick); the Rust `hx palette` is only the fallback
    if bash "$RICE/quickshell/island/scripts/palette.sh" "$first" || { [ -x "$BIN/hx" ] && "$BIN/hx" palette "$first"; }; then
      ok "colours made from $(basename "$first")"
    else warn "could not make colours from the wallpaper (is ImageMagick installed?)"; fi
  fi
}

# ---------------------------------------------------------------------------------------------- terminals
add_line() {   # file marker line : put the include once at the top of the terminal's own config (your settings stay yours)
  mkdir -p "$(dirname "$1")"; [ -f "$1" ] || : > "$1"
  grep -q "$2" "$1" 2>/dev/null && return 0
  { printf '%s\n' "$3"; cat "$1"; } > "$1.new" && mv "$1.new" "$1" && ok "$(basename "$(dirname "$1")"): Halcyon settings included"
}
# ---------------------------------------------------------------------------------------------- terminal look (same in every terminal)
# fish as the shell (only when fish is installed: a terminal told to run a missing shell would not start), JetBrainsMono Nerd Font 11,
# 20x15 padding, 0.85 translucent background (Hyprland blurs it), blinking block cursor, 10 000 lines of scrollback,
# Ctrl+Shift+F = search, Shift+PageUp / PageDown = scroll by page, Ctrl+Shift+Up / Down = scroll by line.
# Written once per terminal as halcyon-style.* next to halcyon-colors.* and included from the terminal's own config
# (your own lines in that config come after the include, so they still win).
terminal_style() {
  local fish="" font="JetBrainsMono Nerd Font" d
  command -v fish >/dev/null 2>&1 && fish=fish
  # ---- foot (alpha / blur live in the same section as the colours: [colors] before foot 1.24, [colors-dark] after)
  local fsec=colors fv fmaj fmin
  if command -v foot >/dev/null 2>&1; then
    fv=$(foot --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -n1); fmaj=${fv%%.*}; fmin=${fv##*.}
    if [ -n "$fv" ] && { [ "${fmaj:-0}" -gt 1 ] || { [ "${fmaj:-0}" -eq 1 ] && [ "${fmin:-0}" -ge 24 ]; }; }; then fsec=colors-dark; fi
  fi
  d="$HOME/.config/foot"; mkdir -p "$d"
  {
    echo "# Halcyon terminal look (written by install.sh / user-setup.sh terminals). Your own foot.ini lines come after this and win."
    echo "[main]"; [ -n "$fish" ] && echo "shell=$fish"
    echo "font=$font:size=11"; echo "pad=20x15"
    echo "[$fsec]"; echo "alpha=0.85"; echo "blur=yes"
    echo "[cursor]"; echo "style=block"; echo "blink=yes"
    echo "[scrollback]"; echo "lines=10000"
    echo "[key-bindings]"
    echo "search-start=Control+Shift+f"
    echo "scrollback-up-page=Shift+Page_Up"; echo "scrollback-down-page=Shift+Page_Down"
    echo "scrollback-up-line=Control+Shift+Up"; echo "scrollback-down-line=Control+Shift+Down"
  } > "$d/halcyon-style.ini"
  # ---- kitty (the compositor blurs the translucent background)
  d="$HOME/.config/kitty"; mkdir -p "$d"
  {
    echo "# Halcyon terminal look (written by install.sh / user-setup.sh terminals). Your own kitty.conf lines come after this and win."
    [ -n "$fish" ] && echo "shell $fish"
    echo "font_family $font"; echo "font_size 11.0"; echo "window_padding_width 15 20"
    echo "background_opacity 0.85"; echo "cursor_shape block"; echo "cursor_blink_interval 0.5"; echo "scrollback_lines 10000"
    echo "map ctrl+shift+f show_scrollback"
    echo "map shift+page_up scroll_page_up"; echo "map shift+page_down scroll_page_down"
    echo "map ctrl+shift+up scroll_line_up"; echo "map ctrl+shift+down scroll_line_down"
  } > "$d/halcyon-style.conf"
  # ---- alacritty (0.13+ names; older versions call the shell table [shell])
  local ash=terminal.shell av
  if command -v alacritty >/dev/null 2>&1; then
    av=$(alacritty --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -n1)
    [ -n "$av" ] && [ "$(printf '%s\n0.13\n' "$av" | sort -V | head -n1)" != "0.13" ] && ash=shell
  fi
  d="$HOME/.config/alacritty"; mkdir -p "$d"
  {
    echo "# Halcyon terminal look (written by install.sh / user-setup.sh terminals). Your own alacritty.toml comes after this and wins."
    [ -n "$fish" ] && { echo "[$ash]"; echo "program = \"$fish\""; }
    echo "[font]"; echo "size = 11.0"; echo "[font.normal]"; echo "family = \"$font\""
    echo "[window]"; echo "opacity = 0.85"; echo "blur = true"; echo "[window.padding]"; echo "x = 20"; echo "y = 15"
    echo "[cursor.style]"; echo "shape = \"Block\""; echo "blinking = \"Always\""
    echo "[scrolling]"; echo "history = 10000"
    # search (Ctrl+Shift+F) and page scrolling (Shift+PageUp / PageDown) are alacritty's own defaults
  } > "$d/halcyon-style.toml"
  # ---- ghostty
  d="$HOME/.config/ghostty"; mkdir -p "$d"
  {
    echo "# Halcyon terminal look (written by install.sh / user-setup.sh terminals). Your own config comes after this and wins."
    [ -n "$fish" ] && echo "command = $(command -v fish)"
    echo "font-family = $font"; echo "font-size = 11"; echo "window-padding-x = 20"; echo "window-padding-y = 15"
    echo "background-opacity = 0.85"; echo "cursor-style = block"; echo "cursor-style-blink = true"
    echo "keybind = shift+page_up=scroll_page_up"; echo "keybind = shift+page_down=scroll_page_down"
  } > "$d/halcyon-style"
  # ---- wezterm: a function the config calls (wezterm.lua is Lua: see wezterm_config below)
  d="$HOME/.config/wezterm"; mkdir -p "$d"
  {
    echo "-- Halcyon terminal look (written by install.sh / user-setup.sh terminals)"
    echo "local wezterm = require 'wezterm'"
    echo "return function(config)"
    [ -n "$fish" ] && echo "  config.default_prog = { '$fish' }"
    echo "  config.font = wezterm.font('$font')"; echo "  config.font_size = 11.0"
    echo "  config.window_padding = { left = 20, right = 20, top = 15, bottom = 15 }"
    echo "  config.window_background_opacity = 0.85"; echo "  config.default_cursor_style = 'BlinkingBlock'"
    echo "  config.scrollback_lines = 10000"
    echo "  config.keys = config.keys or {}"
    echo "  table.insert(config.keys, { key = 'f', mods = 'CTRL|SHIFT', action = wezterm.action.Search('CurrentSelectionOrEmptyString') })"
    echo "  table.insert(config.keys, { key = 'PageUp', mods = 'SHIFT', action = wezterm.action.ScrollByPage(-1) })"
    echo "  table.insert(config.keys, { key = 'PageDown', mods = 'SHIFT', action = wezterm.action.ScrollByPage(1) })"
    echo "  table.insert(config.keys, { key = 'UpArrow', mods = 'CTRL|SHIFT', action = wezterm.action.ScrollByLine(-1) })"
    echo "  table.insert(config.keys, { key = 'DownArrow', mods = 'CTRL|SHIFT', action = wezterm.action.ScrollByLine(1) })"
    echo "  return config"
    echo "end"
  } > "$d/halcyon-style.lua"
  ok "terminal look written for foot, kitty, alacritty, ghostty, wezterm (fish, $font 11, 20x15 padding, 0.85 translucent, blinking block, 10000 lines, Ctrl+Shift+F search)"
}
wezterm_config() {   # wezterm.lua cannot be included: it becomes a small wrapper that loads YOUR config (kept as wezterm-user.lua), then colours + look
  command -v wezterm >/dev/null 2>&1 || return 0
  local w="$HOME/.config/wezterm/wezterm.lua" u="$HOME/.config/wezterm/wezterm-user.lua"
  if [ -f "$w" ] && grep -q "Halcyon wrapper" "$w"; then ok "wezterm: already set up"; return 0; fi
  if [ -f "$w" ]; then
    [ -e "$w.before-halcyon" ] || cp -p "$w" "$w.before-halcyon"
    mv "$w" "$u"; ok "wezterm: your config is now wezterm-user.lua (a copy is wezterm.lua.before-halcyon)"
  fi
  cat > "$w" <<'LUA'
-- Halcyon wrapper (install.sh): your own settings (wezterm-user.lua, if you have one), then the wallpaper colours and the Halcyon look.
-- Delete this file and rename wezterm-user.lua back to wezterm.lua to undo it.
local wezterm = require 'wezterm'
local home = os.getenv('HOME')
local config = {}
local ok, mine = pcall(dofile, home .. '/.config/wezterm/wezterm-user.lua')
if ok and type(mine) == 'table' then config = mine elseif wezterm.config_builder then config = wezterm.config_builder() end
local c_ok, colors = pcall(dofile, home .. '/.config/wezterm/halcyon-colors.lua')
if c_ok and type(colors) == 'table' then config.colors = colors end
local s_ok, style = pcall(dofile, home .. '/.config/wezterm/halcyon-style.lua')
if s_ok and type(style) == 'function' then config = style(config) end
return config
LUA
  ok "wezterm: wezterm.lua now loads the Halcyon colours and look"
}

# the Halcyon look only wins where YOUR terminal config does not set the same thing: remove those lines once (a copy is kept)
strip_look() {
  local f
  f="$HOME/.config/foot/foot.ini"
  if command -v foot >/dev/null && [ -f "$f" ] && [ ! -e "$f.before-halcyon-look" ]; then
    cp -p "$f" "$f.before-halcyon-look"
    awk -v pairs="main:shell main:font main:font-bold main:font-italic main:font-bold-italic main:pad colors:alpha colors:blur colors-dark:alpha colors-dark:blur cursor:style cursor:blink scrollback:lines" '
      BEGIN { n = split(pairs, p, " "); for (i = 1; i <= n; i++) drop[p[i]] = 1; sec = "main" }
      /^\[.*\]/ { sec = $0; gsub(/[\[\]]/, "", sec) }
      { k = $0; sub(/[ \t]*=.*/, "", k); if (!(/^\[/) && ((sec ":" k) in drop)) next; print }' "$f.before-halcyon-look" > "$f"
    cmp -s "$f" "$f.before-halcyon-look" && rm -f "$f.before-halcyon-look" || ok "foot: your own font / padding / shell / cursor / alpha / scrollback lines removed (a copy is foot.ini.before-halcyon-look)"
  fi
  f="$HOME/.config/kitty/kitty.conf"
  if command -v kitty >/dev/null && [ -f "$f" ] && [ ! -e "$f.before-halcyon-look" ]; then
    cp -p "$f" "$f.before-halcyon-look"
    sed -E -i '/^[[:space:]]*(shell|font_family|font_size|window_padding_width|background_opacity|cursor_shape|cursor_blink_interval|scrollback_lines)[[:space:]]/d' "$f"
    cmp -s "$f" "$f.before-halcyon-look" && rm -f "$f.before-halcyon-look" || ok "kitty: your own font / padding / shell / cursor / opacity / scrollback lines removed (a copy is kitty.conf.before-halcyon-look)"
  fi
  f="$HOME/.config/ghostty/config"
  if command -v ghostty >/dev/null && [ -f "$f" ] && [ ! -e "$f.before-halcyon-look" ]; then
    cp -p "$f" "$f.before-halcyon-look"
    sed -E -i '/^[[:space:]]*(command|font-family|font-size|window-padding-x|window-padding-y|background-opacity|cursor-style|cursor-style-blink)[[:space:]]*=/d' "$f"
    cmp -s "$f" "$f.before-halcyon-look" && rm -f "$f.before-halcyon-look" || ok "ghostty: your own font / padding / shell / cursor / opacity lines removed (a copy is config.before-halcyon-look)"
  fi
  # alacritty is TOML (tables, not lines): a table of your own in alacritty.toml beats the included look. Say so instead of editing it.
  f="$HOME/.config/alacritty/alacritty.toml"
  if command -v alacritty >/dev/null && [ -f "$f" ] && grep -qE '^\[(font|font\.normal|window|window\.padding|cursor|cursor\.style|scrolling|shell|terminal\.shell)\]' "$f"; then
    warn "alacritty.toml sets its own font / window / cursor / scrolling / shell: those override the Halcyon look. Delete those tables (or run: sed -i to remove them) to get it"
  fi
}
terminals() {
  bash "$RICE/scripts/term-colors.sh" --now && ok "colour files written for foot, kitty, alacritty, ghostty, wezterm"
  if command -v foot >/dev/null; then
    add_line "$HOME/.config/foot/foot.ini" "halcyon-colors" "include=$HOME/.config/foot/halcyon-colors.ini"
    if [ -f "$HOME/.config/foot/foot.ini" ] && grep -qE '^(foreground|background|cursor|selection-foreground|selection-background|regular[0-7]|bright[0-7])=' "$HOME/.config/foot/foot.ini"; then
      # your own colour lines would override the wallpaper colours: keep a copy, then remove them
      [ -e "$HOME/.config/foot/foot.ini.before-halcyon" ] || cp -p "$HOME/.config/foot/foot.ini" "$HOME/.config/foot/foot.ini.before-halcyon"
      sed -i -E '/^(foreground|background|cursor|selection-foreground|selection-background|regular[0-7]|bright[0-7])=/d' "$HOME/.config/foot/foot.ini"
      ok "foot: your own colour lines removed (a copy is foot.ini.before-halcyon)"
    fi
  fi
  terminal_style
  strip_look
  command -v foot >/dev/null && add_line "$HOME/.config/foot/foot.ini" "halcyon-style" "include=$HOME/.config/foot/halcyon-style.ini"
  command -v kitty >/dev/null && add_line "$HOME/.config/kitty/kitty.conf" "halcyon-colors" "include halcyon-colors.conf"
  command -v kitty >/dev/null && add_line "$HOME/.config/kitty/kitty.conf" "halcyon-style" "include halcyon-style.conf"
  command -v ghostty >/dev/null && add_line "$HOME/.config/ghostty/config" "halcyon-colors" "config-file = halcyon-colors"
  command -v ghostty >/dev/null && add_line "$HOME/.config/ghostty/config" "halcyon-style" "config-file = halcyon-style"
  if command -v alacritty >/dev/null; then
    local a="$HOME/.config/alacritty/alacritty.toml"; mkdir -p "$(dirname "$a")"; [ -f "$a" ] || : > "$a"
    if ! grep -q "halcyon-colors" "$a"; then
      { printf '[general]\nimport = ["~/.config/alacritty/halcyon-colors.toml", "~/.config/alacritty/halcyon-style.toml"]\n\n'; cat "$a"; } > "$a.new" && mv "$a.new" "$a" && ok "alacritty: colours and look included"
    elif ! grep -q "halcyon-style" "$a"; then
      sed -i 's|halcyon-colors.toml"\]|halcyon-colors.toml", "~/.config/alacritty/halcyon-style.toml"]|' "$a" && ok "alacritty: look included"
    fi
  fi
  wezterm_config
  ok "open terminals are repainted on every wallpaper change; Settings > Colours does it on demand"
}

# ---------------------------------------------------------------------------------------------- app themes
app_themes() {
  local s="$HOME/.config/starship.toml"
  # Starship: the Halcyon prompt. Put in place once; your own starship.toml is kept as starship.toml.before-halcyon.
  if [ -f "$RICE/config/starship.toml" ] && command -v starship >/dev/null 2>&1; then
    if [ -f "$s" ] && grep -q "HALCYON STARSHIP PALETTE" "$s"; then ok "starship: the Halcyon prompt is already in place"
    else
      mkdir -p "$HOME/.config"
      [ -f "$s" ] && [ ! -e "$s.before-halcyon" ] && cp -p "$s" "$s.before-halcyon" && ok "starship: your own starship.toml is kept as starship.toml.before-halcyon"
      cp "$RICE/config/starship.toml" "$s" && ok "starship: Halcyon prompt (with the rice name) installed"
    fi
  fi
  # fish: colours (the terminal's ANSI names) + starts Starship
  if [ -f "$RICE/config/fish/halcyon.fish" ] && command -v fish >/dev/null 2>&1; then
    mkdir -p "$HOME/.config/fish/conf.d" && cp "$RICE/config/fish/halcyon.fish" "$HOME/.config/fish/conf.d/halcyon.fish" && ok "fish: colours installed (conf.d/halcyon.fish)"
  fi
  if [ -f "$RICE/config/fish/functions/fish_greeting.fish" ] && command -v fish >/dev/null 2>&1; then
    mkdir -p "$HOME/.config/fish/functions" && cp "$RICE/config/fish/functions/fish_greeting.fish" "$HOME/.config/fish/functions/fish_greeting.fish" && ok "fish: dynamic greeting installed (functions/fish_greeting.fish)"
  fi
  # the palette itself, and btop / yazi / Spotify / Discord
  bash "$RICE/scripts/app-themes.sh" --setup | while IFS= read -r l; do ok "${l#   }"; done
  bash "$RICE/scripts/gtk-theme.sh" && ok "Thunar / GTK apps: colours written"
  return 0
}

# ---------------------------------------------------------------------------------------------- default apps
default_apps() {
  local apps="$RICE/scripts/apps.sh" env="$HOME/.local/state/island/apps.env" kind id cur pick a
  [ -f "$apps" ] || return 0
  # what you picked in the installer (browser= files= editor=): set first, and they replace an older choice
  for a in "$@"; do
    kind=${a%%=*}; id=${a#*=}
    case "$kind" in browser|files|editor) ;; *) continue ;; esac
    [ -n "$id" ] && [ "$id" != keep ] && [ "$id" != none ] || continue
    if bash "$apps" set "$kind" "$id" 2>/dev/null; then ok "default $kind: $id"
    else warn "default $kind: $id is not installed (pick one in Settings > Default apps)"; fi
  done
  # kind:preferred ids in order. Only when you have not picked one for that kind yet; an app that is not installed is skipped.
  for pair in "terminal:foot" "files:thunar" "music:spotify spotify-launcher" "chat:vesktop discord"; do
    kind=${pair%%:*}
    grep -q "^$kind=" "$env" 2>/dev/null && continue
    for id in ${pair#*:}; do
      if bash "$apps" set "$kind" "$id" 2>/dev/null; then ok "default $kind: $id"; break; fi
    done
  done
  return 0
}

# ---------------------------------------------------------------------------------------------- the installer's choices
# BROWSER=firefox FILES="thunar yazi" EDITOR=codium SYSMODE=yes ... : kept per user, so update.sh / a second install.sh run
# installs the same things again without asking (./install.sh --choose asks again)
save_choices() {
  local f="$HOME/.local/state/island/install-choices.env" a k
  mkdir -p "$(dirname "$f")"; [ -f "$f" ] || : > "$f"
  for a in "$@"; do
    k=${a%%=*}
    case "$k" in BROWSER|FILES|EDITOR|SYSMODE|SAFETY_CHECK) ;; *) continue ;; esac
    grep -v "^$k=" "$f" > "$f.new" 2>/dev/null; printf '%s="%s"\n' "$k" "${a#*=}" >> "$f.new"; mv "$f.new" "$f"
  done
  ok "your choices are saved in ~/.local/state/island/install-choices.env"
}

# ---------------------------------------------------------------------------------------------- GPU environment
# NVIDIA on a desktop (the NVIDIA card draws the screen): video acceleration and GLX through the NVIDIA driver.
# Hybrid laptop: NOTHING is forced (the integrated GPU draws the desktop; games: prime-run <game>).
# The file checks at login that the NVIDIA driver is really loaded, so a missing / failed driver can never break the session.
gpu_env() {
  local mode="${1:-none}" f="$RICE/gpu.lua"
  mkdir -p "$RICE"
  case "$mode" in
    nvidia)
      cat > "$f" <<'LUA'
-- Written by install.sh (NVIDIA graphics). Yours to edit or delete: it is kept when you update.
-- Only applied when the NVIDIA kernel driver is really loaded.
local f = io.open("/proc/driver/nvidia/version")
if f then
    f:close()
    hl.env("LIBVA_DRIVER_NAME", "nvidia")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
    hl.env("NVD_BACKEND", "direct")
end
LUA
      ok "gpu.lua: NVIDIA environment (video acceleration, GLX)" ;;
    hybrid)
      cat > "$f" <<'LUA'
-- Written by install.sh (hybrid laptop: integrated GPU + NVIDIA). Yours to edit or delete: it is kept when you update.
-- The integrated GPU draws the desktop (battery); run a game on the NVIDIA GPU with:  prime-run <program>
-- In Steam, set a game's launch options to:  prime-run %command%
LUA
      ok "gpu.lua: hybrid laptop (nothing forced; use prime-run for games)" ;;
    *) [ -f "$f" ] && ! grep -q "Written by install.sh" "$f" && return 0   # not ours: leave it
       rm -f "$f" ;;
  esac
}

case "${1:-}" in
  default-apps)  shift; default_apps "$@" ;;
  save-choices)  shift; save_choices "$@" ;;
  gpu-env)       gpu_env "${2:-none}" ;;
  hypr-entry)    hypr_entry ;;
  login-add)     login_add || { warn "your login shell is not bash, zsh or fish, so the lock-screen login was NOT set up (auto-login without it would leave an open shell)"; exit 1; } ;;
  login-remove)  login_remove ;;
  tty-autostart) tty_autostart ;;
  wallpaper)     wallpaper ;;
  terminals)     terminals ;;
  app-themes)    app_themes ;;
  *) sed -n 2,11p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
