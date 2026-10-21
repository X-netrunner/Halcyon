#!/usr/bin/env bash
# special.sh <name> [--show]      SUPER+M (music), SUPER+D (communication) and the bar / background-apps "Open" buttons.
#   - the special workspace <name> has no windows yet  ->  start its app, and show the workspace so the window lands in view
#   - it has windows                                   ->  toggle it (--show: only ever show it, never hide)
# special.sh --run <name> [default command...]    start the workspace's app now (no toggling). Hyprland calls this when a special
#                                                  workspace is opened empty (hyprland/rules.lua); the default command is the one from variables.lua.
# special.sh list                                  JSON: your own command per special workspace (Settings > Workspaces & windows)
# special.sh set <name> [command...]               set it (no command = back to the default)
#
# Names: special (SUPER+S scratch) | music (SUPER+M) | communication (SUPER+D) | sysmon (CTRL+SHIFT+ESC)
# YOUR OWN COMMAND for any of them wins over everything else. Set it in Settings > Workspaces & windows > "Special workspace
# commands", or by hand: one line in ~/.local/state/island/special-<name>.cmd . It runs whenever that workspace is opened with no window in it.
# Otherwise: music / communication start the "Music player" / "Chat" app from Settings > Default apps (scripts/apps.sh); to force
# something else for those two, set it in ~/.config/Halcyon/special.conf (plain shell):
#   MUSIC_CMD='spotify'
#   COMM_CMD='vesktop'
# SPECIAL_CMD in the environment overrides all of it (the background-apps box uses it to open one specific app).
state="$HOME/.local/state/island"
names="special music communication sysmon"
valid() { case " $names " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
custom() { head -n1 "$state/special-$1.cmd" 2>/dev/null; }
jstr() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g')"; }

case "$1" in
  list)
    out="{"; sep=""
    for n in $names; do out+="$sep\"$n\":$(jstr "$(custom "$n")")"; sep=","; done
    echo "$out}"; exit 0 ;;
  set)
    n="$2"; valid "$n" || { echo "unknown special workspace: $n (use: $names)" >&2; exit 2; }
    shift 2; c="$*"
    mkdir -p "$state"
    if [ -z "${c// /}" ]; then rm -f "$state/special-$n.cmd"; else printf '%s\n' "$c" > "$state/special-$n.cmd"; fi
    exit 0 ;;
  --run)
    n="$2"; valid "$n" || exit 2; shift 2
    c=$(custom "$n")
    if [ -n "$c" ]; then setsid -f bash -c "$c" >/dev/null 2>&1
    elif [ $# -gt 0 ]; then setsid -f "$@" >/dev/null 2>&1; fi
    exit 0 ;;
esac

name="${1:?usage: special.sh <name> [--show]}"; show=0; [ "$2" = "--show" ] && show=1

MUSIC_CMD="$HOME/.config/Halcyon/scripts/apps.sh run music"
COMM_CMD="$HOME/.config/Halcyon/scripts/apps.sh run chat"
[ -f "$HOME/.config/Halcyon/special.conf" ] && . "$HOME/.config/Halcyon/special.conf"

# only music / communication are started from here; the others are started by their workspace rule (--run), so they never start twice
case "$name" in
  music)         cmd="$MUSIC_CMD" ;;
  communication) cmd="$COMM_CMD" ;;
  *)             cmd="" ;;
esac
c=$(custom "$name"); [ -n "$c" ] && [ -n "$cmd" ] && cmd="$c"
[ -n "$SPECIAL_CMD" ] && cmd="$SPECIAL_CMD"

toggle() { hyprctl dispatch "hl.dsp.workspace.toggle_special(\"$name\")" >/dev/null 2>&1; }

# Is the workspace showing / how many windows does it hold? JSON + jq (the text output of hyprctl changes between versions, and
# a wrong answer here used to start the app again). Without jq the old text match is used.
if command -v jq >/dev/null 2>&1; then
  visible=0; hyprctl monitors -j 2>/dev/null | jq -e --arg w "special:$name" 'any(.[]; .specialWorkspace.name == $w)' >/dev/null 2>&1 && visible=1
  count=$(hyprctl clients -j 2>/dev/null | jq --arg w "special:$name" '[.[] | select(.workspace.name == $w)] | length' 2>/dev/null)
  case "$count" in ''|*[!0-9]*) count=-1 ;; esac      # hyprctl did not answer: unknown, so the app is NOT started
else
  visible=0; hyprctl monitors 2>/dev/null | grep -q "special workspace: .*(special:$name)" && visible=1
  count=$(hyprctl clients 2>/dev/null | grep -c "workspace: .*(special:$name)")
fi

# start the app, at most once every 8 seconds per workspace (two quick key presses, or a window that is still being moved in,
# must not start a second copy)
launch() {
  [ -n "$cmd" ] || return 0
  local stamp="${XDG_RUNTIME_DIR:-/tmp}/halcyon-special-$name.stamp" now last
  now=$(date +%s); last=$(cat "$stamp" 2>/dev/null); last=${last:-0}
  [ $((now - last)) -lt 8 ] && return 0
  echo "$now" > "$stamp"
  setsid -f bash -c "$cmd" >/dev/null 2>&1
}

if [ "$visible" = 1 ]; then
  [ "$show" = 1 ] || toggle          # already showing: SUPER+M again hides it
  [ "$count" = 0 ] && launch         # showing but empty: start the app
  exit 0
fi
toggle
[ "$count" = 0 ] && launch
exit 0
