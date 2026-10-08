#!/usr/bin/env bash
# startup-conf.sh : the startup choices the Settings window shows (Settings > Startup & background).
#   startup-conf.sh list               one line of JSON: the current values + what is installed
#   startup-conf.sh set KEY VALUE      KEY = NM_APPLET | BLUEMAN | POLKIT | GPU
#       NM_APPLET / BLUEMAN  0 | 1     takes effect at once (the applet is started / stopped)
#       POLKIT               auto | hyprpolkitagent | gnome | kde | none    takes effect at the next login
#       GPU                  igpu | dgpu                                    takes effect at the next login
# The values live in ~/.config/Halcyon/autostart.conf (read by scripts/autostart-extras.sh) and ~/.config/Halcyon/gpu-mode.
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
conf="$RICE/autostart.conf"

NM_APPLET=0; BLUEMAN=0; POLKIT=auto
[ -f "$conf" ] && . "$conf" 2>/dev/null

gpu_now() { local m=igpu; [ -s "$RICE/gpu-mode" ] && m="$(head -n1 "$RICE/gpu-mode")"; case "$m" in dgpu) echo dgpu ;; *) echo igpu ;; esac; }
have() { command -v "$1" >/dev/null 2>&1; }
exists() { for p in "$@"; do [ -x "$p" ] && return 0; done; return 1; }
b() { "$@" && echo true || echo false; }

write_conf() {   # rewrite the three keys, keep any other line the user added
  mkdir -p "$(dirname "$conf")"
  local tmp; tmp="$(mktemp)"
  { printf 'NM_APPLET=%s\nBLUEMAN=%s\nPOLKIT=%s\n' "$NM_APPLET" "$BLUEMAN" "$POLKIT"
    if [ -f "$conf" ]; then grep -v -E '^(NM_APPLET|BLUEMAN|POLKIT)=' "$conf" || true; fi
  } > "$tmp" && mv "$tmp" "$conf"
}

case "${1:-list}" in
  list)
    nm=false; bl=false; hp=false; gn=false; kd=false; nv=false
    have nm-applet && nm=true
    have blueman-applet && bl=true
    exists /usr/lib/hyprpolkitagent/hyprpolkitagent && hp=true
    exists /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/libexec/polkit-gnome-authentication-agent-1 && gn=true
    exists /usr/lib/polkit-kde-authentication-agent-1 /usr/libexec/polkit-kde-authentication-agent-1 && kd=true
    [ -r /proc/driver/nvidia/version ] && nv=true
    printf '{"NM_APPLET":%s,"BLUEMAN":%s,"POLKIT":"%s","GPU":"%s","has":{"nm":%s,"blueman":%s,"hyprpolkit":%s,"gnome":%s,"kde":%s,"nvidia":%s}}\n' \
      "$([ "$NM_APPLET" = 1 ] && echo true || echo false)" "$([ "$BLUEMAN" = 1 ] && echo true || echo false)" \
      "$POLKIT" "$(gpu_now)" "$nm" "$bl" "$hp" "$gn" "$kd" "$nv"
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
      POLKIT)
        case "$val" in auto|hyprpolkitagent|gnome|kde|none) POLKIT="$val"; write_conf ;; *) echo "bad POLKIT value: $val" >&2; exit 2 ;; esac ;;
      GPU)
        case "$val" in igpu|dgpu) bash "$RICE/scripts/gpu-mode.sh" "$val" >/dev/null ;; *) echo "bad GPU value: $val" >&2; exit 2 ;; esac ;;
      *) echo "unknown key: $key" >&2; exit 2 ;;
    esac
    ;;
  *) echo "usage: startup-conf.sh list | set KEY VALUE" >&2; exit 2 ;;
esac
