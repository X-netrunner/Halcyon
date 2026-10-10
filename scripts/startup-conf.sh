#!/usr/bin/env bash
# startup-conf.sh : the startup choices the Settings window shows (Settings > Startup & background).
#   startup-conf.sh list               one line of JSON: the current values + what is installed
#   startup-conf.sh set KEY VALUE      KEY = NM_APPLET | BLUEMAN | POLKIT | GPU | FILE_ICONS | CLIPBOARD | GESTURES | PORTAL
#       NM_APPLET / BLUEMAN  0 | 1     takes effect at once (the applet is started / stopped)
#       POLKIT               auto | hyprpolkitagent | gnome | kde | none    takes effect at the next login
#       GPU                  igpu | dgpu                                    takes effect at the next login
#       FILE_ICONS           small | medium | large                         Thunar icon size (scripts/thunar-look.sh), at once
#       CLIPBOARD            0 | 1     clipboard history (the two wl-paste watchers + cliphist), started / stopped at once
#       GESTURES             0 | 1     touchpad edge gestures (touchpad-gestures.service), started / stopped at once
#       PORTAL               login | demand   screen-sharing helper: started at login, or only when an app first asks   next login
# The values live in ~/.config/Halcyon/autostart.conf (read by scripts/autostart-extras.sh) and ~/.config/Halcyon/gpu-mode.
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
conf="$RICE/autostart.conf"

NM_APPLET=0; BLUEMAN=0; POLKIT=auto; CLIPBOARD=1; GESTURES=1; PORTAL=login
[ -f "$conf" ] && . "$conf" 2>/dev/null

gpu_now() { local m=igpu; [ -s "$RICE/gpu-mode" ] && m="$(head -n1 "$RICE/gpu-mode")"; case "$m" in dgpu) echo dgpu ;; *) echo igpu ;; esac; }
have() { command -v "$1" >/dev/null 2>&1; }
exists() { for p in "$@"; do [ -x "$p" ] && return 0; done; return 1; }
b() { "$@" && echo true || echo false; }
files_now() { bash "$RICE/scripts/thunar-look.sh" status 2>/dev/null || echo medium; }

write_conf() {   # rewrite our keys, keep any other line the user added
  mkdir -p "$(dirname "$conf")"
  local tmp; tmp="$(mktemp)"
  { printf 'NM_APPLET=%s\nBLUEMAN=%s\nPOLKIT=%s\nCLIPBOARD=%s\nGESTURES=%s\nPORTAL=%s\n' "$NM_APPLET" "$BLUEMAN" "$POLKIT" "$CLIPBOARD" "$GESTURES" "$PORTAL"
    if [ -f "$conf" ]; then grep -v -E '^(NM_APPLET|BLUEMAN|POLKIT|CLIPBOARD|GESTURES|PORTAL)=' "$conf" || true; fi
  } > "$tmp" && mv "$tmp" "$conf"
}

case "${1:-list}" in
  list)
    nm=false; bl=false; hp=false; gn=false; kd=false; nv=false; sf=false
    have nm-applet && nm=true
    have blueman-applet && bl=true
    exists /usr/lib/hyprpolkitagent/hyprpolkitagent && hp=true
    exists /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/libexec/polkit-gnome-authentication-agent-1 && gn=true
    exists /usr/lib/polkit-kde-authentication-agent-1 /usr/libexec/polkit-kde-authentication-agent-1 && kd=true
    [ -r /proc/driver/nvidia/version ] && nv=true
    [ -x /usr/local/bin/safety-check ] && sf=true      # the optional safety check (install.sh asks): Settings greys its entry out without it
    case "$PORTAL" in demand) ;; *) PORTAL=login ;; esac
    printf '{"NM_APPLET":%s,"BLUEMAN":%s,"POLKIT":"%s","GPU":"%s","FILE_ICONS":"%s","CLIPBOARD":%s,"GESTURES":%s,"PORTAL":"%s","has":{"nm":%s,"blueman":%s,"hyprpolkit":%s,"gnome":%s,"kde":%s,"nvidia":%s,"safety":%s}}\n' \
      "$([ "$NM_APPLET" = 1 ] && echo true || echo false)" "$([ "$BLUEMAN" = 1 ] && echo true || echo false)" \
      "$POLKIT" "$(gpu_now)" "$(files_now)" "$([ "$CLIPBOARD" = 1 ] && echo true || echo false)" "$([ "$GESTURES" = 1 ] && echo true || echo false)" "$PORTAL" "$nm" "$bl" "$hp" "$gn" "$kd" "$nv" "$sf"
    ;;
  set)
    key="$2"; val="$3"
    case "$key" in
      NM_APPLET)
        case "$val" in 1|true|on) NM_APPLET=1 ;; *) NM_APPLET=0 ;; esac
        write_conf
        if [ "$NM_APPLET" = 1 ]; then
          have nm-applet && ! pgrep -x nm-applet >/dev/null && setsid -f nm-applet >/dev/null 2>&1 </dev/null
        else pkill -x nm-applet 2>/dev/null; fi ;;
      BLUEMAN)
        case "$val" in 1|true|on) BLUEMAN=1 ;; *) BLUEMAN=0 ;; esac
        write_conf
        if [ "$BLUEMAN" = 1 ]; then
          have blueman-applet && ! pgrep -f blueman-applet >/dev/null && setsid -f blueman-applet >/dev/null 2>&1 </dev/null
        else pkill -f blueman-applet 2>/dev/null; fi ;;
      CLIPBOARD)
        case "$val" in 1|true|on) CLIPBOARD=1 ;; *) CLIPBOARD=0 ;; esac
        write_conf
        if [ "$CLIPBOARD" = 1 ]; then
          if have wl-paste && have cliphist && ! pgrep -f 'wl-pas[t].*--watch cliphist' >/dev/null; then
            setsid -f wl-paste --type text --watch cliphist store >/dev/null 2>&1 </dev/null
            setsid -f wl-paste --type image --watch cliphist store >/dev/null 2>&1 </dev/null
          fi
        else pkill -f 'wl-pas[t].*--watch cliphist' 2>/dev/null; fi ;;
      GESTURES)
        case "$val" in 1|true|on) GESTURES=1 ;; *) GESTURES=0 ;; esac
        write_conf
        if [ "$GESTURES" = 1 ]; then systemctl --user start touchpad-gestures.service >/dev/null 2>&1
        else systemctl --user stop touchpad-gestures.service >/dev/null 2>&1; fi ;;
      PORTAL)
        case "$val" in login|demand) PORTAL="$val"; write_conf ;; *) echo "bad PORTAL value: $val" >&2; exit 2 ;; esac ;;
      POLKIT)
        case "$val" in auto|hyprpolkitagent|gnome|kde|none) POLKIT="$val"; write_conf ;; *) echo "bad POLKIT value: $val" >&2; exit 2 ;; esac ;;
      GPU)
        case "$val" in igpu|dgpu) bash "$RICE/scripts/gpu-mode.sh" "$val" >/dev/null ;; *) echo "bad GPU value: $val" >&2; exit 2 ;; esac ;;
      FILE_ICONS)
        case "$val" in small|medium|large) bash "$RICE/scripts/thunar-look.sh" "$val" ;; *) echo "bad FILE_ICONS value: $val" >&2; exit 2 ;; esac ;;
      *) echo "unknown key: $key" >&2; exit 2 ;;
    esac
    ;;
  *) echo "usage: startup-conf.sh list | set KEY VALUE" >&2; exit 2 ;;
esac
