#!/usr/bin/env bash
# input-conf.sh: touchpad gestures and mouse buttons (Settings > Touchpad gestures / Mouse buttons).
#
#   input-conf.sh conf                  one line of JSON: every gesture, every mouse button, and the mice that are connected
#   input-conf.sh mice                  JSON list of the connected mice (touchpads and virtual devices left out)
#   input-conf.sh set ID ACTION [CMD]   assign an action (CMD is the command for the actions "app" and "cmd")
#   input-conf.sh reset [gestures|mouse|all]
#   input-conf.sh run ID                what a gesture / button does (called by Hyprland: hyprland/gestures.lua, hyprland/mouse.lua)
#
# IDs:  g3-left g3-right g3-up g3-down g3-pinchin g3-pinchout   (3 fingers; g4-... is the same with 4 fingers)
#       m274 (middle) m275 (back) m276 (forward) m277 m278 m279 (more buttons, gaming mice)
#
# The choices live in ~/.local/state/island/gestures.conf, one `id=action` line each (and `id.cmd=...` for a command).
# An id that is not in the file has its default (below). hyprland/inputconf.lua reads the same file, and has the same
# defaults, so keep the two in step. Hyprland has to be reloaded for a change from "nothing" to an action (or back) to
# count: only gestures / buttons that do something are registered, so the others still reach your apps. Settings does it.
state="$HOME/.local/state/island"
conf="$state/gestures.conf"
H="$HOME/.config/Halcyon"

GIDS=()
for f in 3 4; do for d in left right up down pinchin pinchout; do GIDS+=("g$f-$d"); done; done
MIDS=(m274 m275 m276 m277 m278 m279)

# ---- defaults (the way Halcyon always behaved: 4 fingers = workspaces, 3 fingers up / down = scratch, ...)
default_of() {
  case "$1" in
    g3-up|g3-down)         echo scratch ;;
    g3-pinchin|g3-pinchout) echo overview ;;
    g4-left)  [ "$(head -n1 "$state/ws-swipe4" 2>/dev/null)" = right ] && echo ws-prev || echo ws-next ;;
    g4-right) [ "$(head -n1 "$state/ws-swipe4" 2>/dev/null)" = right ] && echo ws-next || echo ws-prev ;;
    g4-down)               echo sleep ;;
    *)                     echo none ;;
  esac
}

declare -A A C     # A[id] = action, C[id] = command
load() {
  local id k v
  for id in "${GIDS[@]}" "${MIDS[@]}"; do A[$id]="$(default_of "$id")"; C[$id]=""; done
  [ -f "$conf" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      *=*) k="${line%%=*}"; v="${line#*=}"
           case "$k" in
             *.cmd) id="${k%.cmd}"; [ -n "${A[$id]+x}" ] && C[$id]="$v" ;;
             *)     [ -n "${A[$k]+x}" ] && A[$k]="$v" ;;
           esac ;;
    esac
  done < "$conf"
}

save() {
  local id tmp
  mkdir -p "$state"
  tmp="$(mktemp "$state/.gestures.XXXXXX")" || return 1
  for id in "${GIDS[@]}" "${MIDS[@]}"; do
    printf '%s=%s\n' "$id" "${A[$id]}"
    [ -n "${C[$id]}" ] && printf '%s.cmd=%s\n' "$id" "${C[$id]}"
  done > "$tmp"
  mv -f "$tmp" "$conf"
}

valid_id() { local id; for id in "${GIDS[@]}" "${MIDS[@]}"; do [ "$id" = "$1" ] && return 0; done; return 1; }

# ---- JSON by hand (no jq needed): ids and actions are plain [a-z0-9-], only a command or a device name needs escaping
jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"; printf '%s' "$s"; }

# ---- mice: what Hyprland calls a mouse includes the touchpad and a few virtual devices; those are not mice
mice_json() {
  local out="" n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s' "$n" | grep -qiE 'touchpad|trackpad|synaptics|glidepoint|virtual|ydotool|uinput|keyboard|kbd|power-button|video-bus|stylus|pen$' && continue
    out+="${out:+,}\"$n\""      # already JSON-escaped: it was cut out of hyprctl's own JSON
  done < <(timeout 2 hyprctl devices -j 2>/dev/null | awk '
    /"mice": *\[/ { m = 1; next }
    m && /^[ \t]*\],?[ \t]*$/ { m = 0 }
    m && /"name": *"/ { sub(/.*"name": *"/, ""); sub(/",?[ \t]*$/, ""); print }' | sort -u)
  printf '[%s]' "$out"
}

cmd_conf() {
  load
  local id g="" m=""
  for id in "${GIDS[@]}"; do g+="${g:+,}\"$id\":{\"a\":\"${A[$id]}\",\"c\":\"$(jesc "${C[$id]}")\"}"; done
  for id in "${MIDS[@]}"; do m+="${m:+,}\"$id\":{\"a\":\"${A[$id]}\",\"c\":\"$(jesc "${C[$id]}")\"}"; done
  printf '{"gestures":{%s},"mouse":{%s},"mice":%s}\n' "$g" "$m" "$(mice_json)"
}

cmd_set() {
  local id="$1" act="$2" cmd="${3:-}"
  valid_id "$id" || { echo "unknown id: $id" >&2; exit 2; }
  case "$act" in ''|*[!a-z0-9-]*) echo "bad action: $act" >&2; exit 2 ;; esac
  cmd="${cmd//$'\n'/ }"
  load
  A[$id]="$act"
  case "$act" in app|cmd) C[$id]="$cmd" ;; *) C[$id]="" ;; esac
  save
}

cmd_reset() {
  local what="${1:-all}" id
  load
  case "$what" in gestures|all) for id in "${GIDS[@]}"; do A[$id]="$(default_of "$id")"; C[$id]=""; done ;; esac
  case "$what" in mouse|all)    for id in "${MIDS[@]}"; do A[$id]=none; C[$id]=""; done ;; esac
  save
}

# ---- what an action does
ipc() { quickshell ipc -p "$H/quickshell/island" call island "$1" >/dev/null 2>&1; }
hd()  { hyprctl dispatch "$1" >/dev/null 2>&1; }

do_action() {   # ACTION [COMMAND]
  case "$1" in
    ''|none) ;;
    ws-next)    exec "$H/scripts/ws-nav.sh" next ;;
    ws-prev)    exec "$H/scripts/ws-nav.sh" prev ;;
    scratch)    hd 'hl.dsp.workspace.toggle_special("special")' ;;
    sysmon)     hd 'hl.dsp.workspace.toggle_special("sysmon")' ;;
    todo)       ipc calendar ;;                       # was the Todoist workspace; now the Halcyon calendar
    music)      exec "$H/scripts/special.sh" music ;;
    comm)       exec "$H/scripts/special.sh" communication ;;
    overview|launcher|settings|cheatsheet|notifcenter|quickterm|lock|dnd|clearnotifs|gaming|caffeine|focus) ipc "$1" ;;
    sleep)      exec systemctl suspend ;;
    fullscreen) hd 'hl.dsp.window.fullscreen()' ;;
    float)      hd 'hl.dsp.window.float()' ;;
    pin)        hd 'hl.dsp.window.pin()' ;;
    close)      exec "$H/scripts/close.sh" ;;
    focus-left)  hd 'hl.dsp.focus({ direction = "left" })' ;;
    focus-right) hd 'hl.dsp.focus({ direction = "right" })' ;;
    screenshot) exec "$H/scripts/screenshot-area.sh" ;;
    playpause)  exec playerctl play-pause ;;
    nexttrack)  exec playerctl next ;;
    prevtrack)  exec playerctl previous ;;
    volup)      exec wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+ ;;
    voldown)    exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
    mute)       exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
    brightup)   exec brightnessctl set 10%+ ;;
    brightdown) exec brightnessctl set 10%- ;;
    terminal|browser|files|editor) exec "$H/scripts/apps.sh" run "$1" ;;
    app|cmd)    [ -n "$2" ] && { setsid sh -c "$2" >/dev/null 2>&1 < /dev/null & } ;;
  esac
  return 0
}

cmd_run() {
  local id="$1"
  valid_id "$id" || exit 2
  load
  do_action "${A[$id]}" "${C[$id]}"
}

case "${1:-conf}" in
  conf)  cmd_conf ;;
  mice)  mice_json ;;
  set)   shift; cmd_set "$@" ;;
  reset) shift; cmd_reset "$@" ;;
  run)   shift; cmd_run "$@" ;;
  *)     sed -n '2,11p' "$0"; exit 2 ;;
esac
