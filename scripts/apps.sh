#!/usr/bin/env bash
# Default apps for Halcyon: terminal, browser, file manager.  The choice is saved in ~/.local/state/island/apps.env,
# so it changes live (no Hyprland reload): the keybinds call `apps.sh run <kind>` every time.
#   apps.sh list                   JSON: installed choices per kind + the one in use (the island's Settings reads this)
#   apps.sh set <kind> <id>        choose one (browser / files also become the xdg default)
#   apps.sh run <kind> [args...]   start the chosen app
#   apps.sh term-exec cmd [args]   run a command inside the chosen terminal (works for foot, kitty, alacritty, ...)
# kinds: terminal | browser | files
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
  "yazi|Yazi|yazi||1" "dolphin|Dolphin|dolphin|org.kde.dolphin.desktop|0" "nautilus|Files|nautilus|org.gnome.Nautilus.desktop|0"
  "thunar|Thunar|thunar|thunar.desktop|0" "nemo|Nemo|nemo|nemo.desktop|0" "pcmanfm|PCManFM|pcmanfm|pcmanfm.desktop|0"
  "pcmanfm-qt|PCManFM-Qt|pcmanfm-qt|pcmanfm-qt.desktop|0" "caja|Caja|caja|caja.desktop|0" "ranger|Ranger|ranger||1" "lf|lf|lf||1" "nnn|nnn|nnn||1"
)

table() { case "$1" in terminal) printf '%s\n' "${terminals[@]}" ;; browser) printf '%s\n' "${browsers[@]}" ;; files) printf '%s\n' "${files[@]}" ;; *) return 1 ;; esac; }
installed() { local l; while IFS='|' read -r id name bin desk tui; do command -v "$bin" >/dev/null 2>&1 && echo "$id|$name|$bin|$desk|$tui"; done < <(table "$1"); }
saved() { [ -f "$envf" ] && sed -n "s/^$1=//p" "$envf" | tail -n1; }
# the chosen id if it is still installed, else the first installed one
current() {
  local want; want=$(saved "$1")
  if [ -n "$want" ] && installed "$1" | cut -d'|' -f1 | grep -qx "$want"; then echo "$want"; return; fi
  installed "$1" | head -n1 | cut -d'|' -f1
}
field() { installed "$1" | awk -F'|' -v id="$2" -v n="$3" '$1==id {print $n}'; }

kind=$1
case "$1" in
  list)
    out="{"; sep=""
    for k in terminal browser files; do
      out+="$sep\"$k\":["; first=1
      while IFS='|' read -r id name _; do
        [ -n "$id" ] || continue
        [ $first = 1 ] || out+=","; first=0
        out+="{\"id\":\"$id\",\"name\":\"$name\"}"
      done < <(installed "$k")
      out+="]"; sep=","
    done
    out+=",\"current\":{\"terminal\":\"$(current terminal)\",\"browser\":\"$(current browser)\",\"files\":\"$(current files)\"}}"
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
    fi
    ;;
  run)
    k=$2; shift 2
    id=$(current "$k"); [ -n "$id" ] || { notify-send -a Halcyon "No $k found" "Install one (see Settings > Default apps)" 2>/dev/null; exit 1; }
    bin=$(field "$k" "$id" 3); tui=$(field "$k" "$id" 5)
    if [ "$tui" = 1 ]; then exec bash "$0" term-exec "$bin" "$@"; fi
    exec "$bin" "$@"
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
  *) echo "usage: apps.sh list | set <terminal|browser|files> <id> | run <kind> [args] | term-exec cmd [args]" >&2; exit 2 ;;
esac
