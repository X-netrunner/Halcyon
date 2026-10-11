#!/usr/bin/env bash
# Default apps for Halcyon: terminal, browser, file manager, code editor, music player, chat.  The choice is saved in
# ~/.local/state/island/apps.env, so it changes live (no Hyprland reload): the keybinds call `apps.sh run <kind>` every time.
#   apps.sh list                   JSON: installed choices per kind + the one in use (the island's Settings reads this)
#   apps.sh set <kind> <id>        choose one (browser / files also become the xdg default)
#   apps.sh run <kind> [args...]   start the chosen app (editor: pass a file or folder; nothing installed -> xdg-open + a notification)
#   apps.sh term-exec cmd [args]   run a command inside the chosen terminal (works for foot, kitty, alacritty, ...)
# kinds: terminal | browser | files | editor | music | chat
#
#   apps.sh add-web <Name> <url>   add a website as a chat app (WhatsApp Web ...), chosen at once. It opens in your chosen browser as its
#                                  own window (Chromium family: --app, no tabs or address bar; others: a new window).
#   apps.sh remove-web <id>        take one of those away again
#   (the same by hand in apps.custom:   chat|whatsapp|WhatsApp|web:https://web.whatsapp.com||0 )
#
# An app that is not in the tables below?  Add a line to ~/.config/Halcyon/apps.custom (same format as the tables,
# with the kind in front):   kind|id|Name|binary|desktop-file (optional)|tui (1 = needs a terminal)
#   editor|lapce|Lapce|lapce||0
state="$HOME/.local/state/island"; envf="$state/apps.env"
mkdir -p "$state"

# id|name|binary|desktop file (for xdg defaults, optional)|tui (1 = needs a terminal)
terminals=(
  "foot|Foot|foot||0" "kitty|Kitty|kitty||0" "alacritty|Alacritty|alacritty||0" "wezterm|WezTerm|wezterm||0"
  "ghostty|Ghostty|ghostty||0" "konsole|Konsole|konsole||0" "gnome-terminal|GNOME Terminal|gnome-terminal||0" "xterm|XTerm|xterm||0"
)
browsers=(
  "firefox|Firefox|firefox|firefox.desktop|0" "zen|Zen|zen-browser|zen.desktop|0" "librewolf|LibreWolf|librewolf|librewolf.desktop|0"
  "floorp|Floorp|floorp|floorp.desktop|0" "chromium|Chromium|chromium|chromium.desktop|0"
  "chrome|Chrome|google-chrome-stable|google-chrome.desktop|0" "brave|Brave|brave|brave-browser.desktop|0"
  "vivaldi|Vivaldi|vivaldi-stable|vivaldi-stable.desktop|0" "qutebrowser|qutebrowser|qutebrowser|org.qutebrowser.qutebrowser.desktop|0"
)
files=(
  "yazi|Yazi|yazi|yazi.desktop|1" "dolphin|Dolphin|dolphin|org.kde.dolphin.desktop|0" "nautilus|Files|nautilus|org.gnome.Nautilus.desktop|0"
  "thunar|Thunar|thunar|thunar.desktop|0" "nemo|Nemo|nemo|nemo.desktop|0" "pcmanfm|PCManFM|pcmanfm|pcmanfm.desktop|0"
  "pcmanfm-qt|PCManFM-Qt|pcmanfm-qt|pcmanfm-qt.desktop|0" "caja|Caja|caja|caja.desktop|0" "ranger|Ranger|ranger||1" "lf|lf|lf||1" "nnn|nnn|nnn||1"
)

# code editors (GUI first, terminal ones last). A TUI editor opens inside the chosen terminal.
editors=(
  "codium|VSCodium|codium|codium.desktop|0" "code|VS Code|code|code.desktop|0" "code-oss|Code - OSS|code-oss|code-oss.desktop|0"
  "cursor|Cursor|cursor|cursor.desktop|0" "zeditor|Zed|zeditor|dev.zed.Zed.desktop|0" "zed|Zed|zed|dev.zed.Zed.desktop|0"
  "sublime|Sublime Text|subl|sublime_text.desktop|0" "kate|Kate|kate|org.kde.kate.desktop|0" "gnome-text-editor|Text Editor|gnome-text-editor|org.gnome.TextEditor.desktop|0"
  "gedit|gedit|gedit|org.gnome.gedit.desktop|0" "mousepad|Mousepad|mousepad|org.xfce.mousepad.desktop|0" "geany|Geany|geany|geany.desktop|0"
  "emacs|Emacs|emacs|emacs.desktop|0" "lapce|Lapce|lapce|dev.lapce.lapce.desktop|0"
  "nvim|Neovim|nvim||1" "helix|Helix|helix||1" "micro|micro|micro||1" "vim|Vim|vim||1" "nano|nano|nano||1"
)
# music players
musics=(
  "spotify|Spotify|spotify|spotify.desktop|0" "spotify-launcher|Spotify (launcher)|spotify-launcher||0" "strawberry|Strawberry|strawberry|org.strawberrymusicplayer.strawberry.desktop|0"
  "rhythmbox|Rhythmbox|rhythmbox|org.gnome.Rhythmbox3.desktop|0" "lollypop|Lollypop|lollypop|org.gnome.Lollypop.desktop|0" "amberol|Amberol|amberol|io.bassi.Amberol.desktop|0"
  "elisa|Elisa|elisa|org.kde.elisa.desktop|0" "clementine|Clementine|clementine|org.clementine_player.Clementine.desktop|0" "deadbeef|DeaDBeeF|deadbeef|deadbeef.desktop|0"
  "youtube-music|YouTube Music|youtube-music||0" "pear-desktop|Pear Desktop|pear-desktop||0" "feishin|Feishin|feishin||0"
  "ncmpcpp|ncmpcpp|ncmpcpp||1" "cmus|cmus|cmus||1" "rmpc|rmpc|rmpc||1" "termusic|Termusic|termusic||1" "musikcube|musikcube|musikcube||1"
)
# chat / communication (SUPER+D)
chats=(
  "vesktop|Vesktop|vesktop|vesktop.desktop|0" "discord|Discord|discord|discord.desktop|0" "telegram|Telegram|telegram-desktop|org.telegram.desktop.desktop|0"
  "signal|Signal|signal-desktop|signal-desktop.desktop|0" "element|Element|element-desktop|element-desktop.desktop|0" "slack|Slack|slack|slack.desktop|0"
  "teams|Teams|teams-for-linux|teams-for-linux.desktop|0" "weechat|WeeChat|weechat||1" "irssi|irssi|irssi||1"
  # websites, opened in your browser as their own window (they are listed whenever a browser is installed)
  "whatsapp-web|WhatsApp|web:https://web.whatsapp.com||0" "telegram-web|Telegram (web)|web:https://web.telegram.org/a/||0"
  "messenger-web|Messenger|web:https://www.messenger.com||0" "google-messages|Google Messages|web:https://messages.google.com/web||0"
  "discord-web|Discord (web)|web:https://discord.com/app||0" "teams-web|Teams (web)|web:https://teams.microsoft.com||0"
)
custom="$HOME/.config/Halcyon/apps.custom"

kinds="terminal browser files editor music chat"
table() {
  case "$1" in
    terminal) printf '%s\n' "${terminals[@]}" ;; browser) printf '%s\n' "${browsers[@]}" ;; files) printf '%s\n' "${files[@]}" ;;
    editor) printf '%s\n' "${editors[@]}" ;; music) printf '%s\n' "${musics[@]}" ;; chat) printf '%s\n' "${chats[@]}" ;;
    *) return 1 ;;
  esac
  # your own lines (apps.custom), listed after the built-in ones
  [ -f "$custom" ] && awk -F'|' -v k="$1" '$1==k && NF>=4 { printf "%s|%s|%s|%s|%s\n", $2, $3, $4, $5, $6 }' "$custom"
}
# a web app (binary = web:URL) counts as installed when some browser is
have_browser() { local id name bin d t; while IFS='|' read -r id name bin d t; do command -v "$bin" >/dev/null 2>&1 && return 0; done < <(table browser); return 1; }
installed() {
  local id name bin desk tui web=""
  while IFS='|' read -r id name bin desk tui; do
    case "$bin" in
      web:*) [ -z "$web" ] && { have_browser && web=1 || web=0; }; [ "$web" = 1 ] && echo "$id|$name|$bin|$desk|$tui" ;;
      *) command -v "$bin" >/dev/null 2>&1 && echo "$id|$name|$bin|$desk|$tui" ;;
    esac
  done < <(table "$1")
}
saved() { [ -f "$envf" ] && sed -n "s/^$1=//p" "$envf" | tail -n1; }
# the chosen id if it is still installed, else the first installed app (never a website: those only run when you pick them)
current() {
  local want; want=$(saved "$1")
  if [ -n "$want" ] && installed "$1" | cut -d'|' -f1 | grep -qx "$want"; then echo "$want"; return; fi
  installed "$1" | grep -v '|web:' | head -n1 | cut -d'|' -f1
}
# open a website as its own window in the chosen browser
open_web() {
  local url="$1" bid bbin; bid=$(current browser); bbin=$(field browser "$bid" 3)
  [ -n "$bbin" ] || { notify-send -a Halcyon "No browser found" "Install one to open $url" 2>/dev/null; exit 1; }
  case "$bid" in
    chromium|chrome|brave|vivaldi) exec "$bbin" --app="$url" ;;
    qutebrowser) exec "$bbin" "$url" ;;
    *) exec "$bbin" --new-window "$url" ;;
  esac
}
field() { installed "$1" | awk -F'|' -v id="$2" -v n="$3" '$1==id {print $n}'; }

kind=$1
case "$1" in
  list)
    out="{"; sep=""
    for k in $kinds; do
      out+="$sep\"$k\":["; first=1
      while IFS='|' read -r id name _; do
        [ -n "$id" ] || continue
        [ $first = 1 ] || out+=","; first=0
        isc=false; [ -f "$custom" ] && awk -F'|' -v k="$k" -v i="$id" '$1==k && $2==i {f=1} END {exit !f}' "$custom" && isc=true
        out+="{\"id\":\"$id\",\"name\":\"$name\",\"custom\":$isc}"
      done < <(installed "$k")
      out+="]"; sep=","
    done
    out+=",\"current\":{"; sep=""
    for k in $kinds; do out+="$sep\"$k\":\"$(current $k)\""; sep=","; done
    out+="}}"
    echo "$out"
    ;;
  set)
    k=$2; id=$3
    installed "$k" | cut -d'|' -f1 | grep -qx "$id" || { echo "$id is not installed" >&2; exit 1; }
    touch "$envf"; grep -v "^$k=" "$envf" > "$envf.tmp" 2>/dev/null; echo "$k=$id" >> "$envf.tmp"; mv "$envf.tmp" "$envf"
    desk=$(field "$k" "$id" 4)
    if [ -n "$desk" ] && [ -n "$(ls /usr/share/applications/"$desk" ~/.local/share/applications/"$desk" 2>/dev/null)" ]; then
      [ "$k" = browser ] && { xdg-settings set default-web-browser "$desk" 2>/dev/null; xdg-mime default "$desk" x-scheme-handler/http x-scheme-handler/https text/html 2>/dev/null; }
      [ "$k" = files ] && xdg-mime default "$desk" inode/directory 2>/dev/null
      # a code editor opens plain text and source files (a GUI editor only: a terminal editor has no desktop file here)
      [ "$k" = editor ] && xdg-mime default "$desk" text/plain text/markdown text/x-shellscript text/x-python text/x-csrc text/x-c++src text/x-rust application/json application/x-yaml application/toml 2>/dev/null
    fi
    ;;
  run)
    k=$2; shift 2
    id=$(current "$k")
    if [ -z "$id" ]; then
      notify-send -a Halcyon "No $k app found" "Install one, then pick it in Settings > Default apps" 2>/dev/null
      # a folder / file we were asked to open can still go to whatever the system uses
      [ -n "$1" ] && [ -e "$1" ] && setsid -f xdg-open "$1" >/dev/null 2>&1
      exit 1
    fi
    bin=$(field "$k" "$id" 3); tui=$(field "$k" "$id" 5)
    case "$bin" in web:*) open_web "${bin#web:}" ;; esac
    if [ "$tui" = 1 ]; then exec bash "$0" term-exec "$bin" "$@"; fi
    exec "$bin" "$@"
    ;;
  add-web)
    name=$(printf '%s' "$2" | tr -d '|"\\' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'); url=$(printf '%s' "$3" | tr -d '[:space:]')
    [ -n "$name" ] && [ -n "$url" ] || { echo "usage: apps.sh add-web <Name> <url>" >&2; exit 2; }
    case "$url" in *'|'*) echo "a | cannot be in a URL" >&2; exit 2 ;; http://*|https://*) ;; *) url="https://$url" ;; esac
    id="web-$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
    mkdir -p "$(dirname "$custom")"; touch "$custom"
    grep -v "^chat|$id|" "$custom" > "$custom.tmp"; echo "chat|$id|$name|web:$url||0" >> "$custom.tmp"; mv "$custom.tmp" "$custom"
    bash "$0" set chat "$id"; echo "$id"
    ;;
  remove-web)
    id="${2:?usage: apps.sh remove-web <id>}"
    [ -f "$custom" ] && { grep -v "^chat|$id|" "$custom" > "$custom.tmp"; mv "$custom.tmp" "$custom"; }
    [ -f "$envf" ] && { grep -v "^chat=$id\$" "$envf" > "$envf.tmp"; mv "$envf.tmp" "$envf"; }
    ;;
  term-exec)
    shift
    id=$(current terminal); [ -n "$id" ] || { notify-send -a Halcyon "No terminal found" 2>/dev/null; exit 1; }
    bin=$(field terminal "$id" 3)
    # the terminals inherit the working directory of this process, so `cd` before calling is enough for all of them
    case "$id" in
      foot|alacritty|xterm|konsole|ghostty) exec "$bin" -e "$@" ;;
      kitty) exec "$bin" "$@" ;;
      wezterm) exec "$bin" start -- "$@" ;;
      gnome-terminal) exec "$bin" -- "$@" ;;
      *) exec "$bin" -e "$@" ;;
    esac
    ;;
  *) echo "usage: apps.sh list | set <terminal|browser|files|editor|music|chat> <id> | run <kind> [args] | add-web <Name> <url> | remove-web <id> | term-exec cmd [args]" >&2; exit 2 ;;
esac
