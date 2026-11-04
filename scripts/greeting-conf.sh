#!/usr/bin/env bash
# greeting-conf.sh : the logo of the fish greeting (Settings > Terminal greeting). The greeting itself is config/fish/functions/fish_greeting.fish.
#   greeting-conf.sh list              one line of JSON: the current choice, and whether a custom ASCII file exists
#   greeting-conf.sh set LOGO VALUE    VALUE = adaptive | arch | blackarch | kali | linux | custom | none | off
#       adaptive   the logo of the system you are on (Arch family -> Arch, BlackArch, Kali, anything else -> Linux)
#       custom     your own ASCII art (see paste / import / edit)      none   no logo, only the info      off   no greeting
#   greeting-conf.sh paste             the text in the clipboard becomes your custom ASCII art, and the greeting switches to it
#   greeting-conf.sh import FILE       the same, from a text file
#   greeting-conf.sh edit              open the custom file in your editor (starts from the Linux logo when there is none yet)
#   greeting-conf.sh preview           show the greeting here
# In the art, @C1@ switches to the main colour (the wallpaper's accent) and @C2@ to the grey one; a line without markers is in the main
# colour. Ready-made colour codes (ESC[...m, e.g. from ascii-image-converter or chafa) work too and are kept; any other escape code is
# dropped when you paste or import. At most 40 rows are shown.
# The values live in ~/.config/Halcyon/greeting.conf (LOGO=...) and ~/.config/Halcyon/greeting-custom.txt (both are yours, git ignores them).
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
conf="$RICE/greeting.conf"
custom="$RICE/greeting-custom.txt"
VALID="adaptive arch blackarch kali linux custom none off"

note() { notify-send -a Halcyon "Terminal greeting" "$1" 2>/dev/null; echo "$1" >&2; }

current() {
  local v=""
  [ -f "$conf" ] && v="$(sed -n 's/^LOGO=\([a-z]*\).*/\1/p' "$conf" | head -n1)"
  case " $VALID " in *" $v "*) echo "$v" ;; *) echo adaptive ;; esac
}

write_conf() {   # LOGO=value on the first line; any other line the user added stays
  local tmp
  mkdir -p "$RICE" || return 1
  tmp="$(mktemp "$RICE/.greeting.XXXXXX")" || return 1
  { printf 'LOGO=%s\n' "$1"; if [ -f "$conf" ]; then grep -v '^LOGO=' "$conf" || true; fi; } > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
}

# stdin -> stdout: no CR, tabs as 4 spaces, only colour codes kept (every other escape / control code dropped), no blank rows at the end, 40 rows at most.
# Exit 1 when nothing is left.
read -r -d '' CLEAN <<'PY'
import re, sys
t = sys.stdin.buffer.read(200000).decode("utf-8", "replace")
t = t.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ")
t = re.sub(r"\x1b\[[0-9;:]*m", lambda m: "\ue000" + m.group(0)[1:], t)      # keep colour codes
t = re.sub(r"[\x00-\x09\x0b-\x1f\x7f]", "", t)                              # everything else that is a control code goes
t = t.replace("\ue000", "\x1b")
rows = t.split("\n")
while rows and not rows[-1].strip():
    rows.pop()
rows = rows[:40]
if not rows or not any(r.strip() for r in rows):
    sys.exit(1)
sys.stdout.write("\n".join(rows) + "\n")
PY

save_custom() {   # reads stdin; on success the greeting uses it
  command -v python3 >/dev/null 2>&1 || { note "python3 is needed to tidy the text"; return 1; }
  local tmp
  mkdir -p "$RICE" || return 1
  tmp="$(mktemp "$RICE/.greeting.XXXXXX")" || return 1
  if python3 -c "$CLEAN" > "$tmp"; then
    chmod 644 "$tmp" && mv "$tmp" "$custom" && write_conf custom && note "Your ASCII art is saved. Open a new terminal to see it."
  else
    rm -f "$tmp"; note "There was no text to use."; return 1
  fi
}

case "${1:-list}" in
  list)
    printf '{"LOGO":"%s","custom":%s}\n' "$(current)" "$([ -s "$custom" ] && echo true || echo false)"
    ;;
  set)
    [ "$2" = LOGO ] || { echo "usage: greeting-conf.sh set LOGO <$(echo $VALID | tr ' ' '|')>" >&2; exit 2; }
    case " $VALID " in *" $3 "*) write_conf "$3" ;; *) echo "greeting-conf.sh: unknown logo '$3' ($VALID)" >&2; exit 2 ;; esac
    ;;
  paste)
    command -v wl-paste >/dev/null 2>&1 || { note "wl-clipboard (wl-paste) is not installed"; exit 1; }
    wl-paste --no-newline 2>/dev/null | save_custom
    ;;
  import)
    [ -r "$2" ] || { echo "usage: greeting-conf.sh import FILE" >&2; exit 2; }
    save_custom < "$2"
    ;;
  edit)
    if [ ! -s "$custom" ]; then
      mkdir -p "$RICE" && cp "$RICE/config/fish/greeting/logos/linux.txt" "$custom" 2>/dev/null || : > "$custom"
      write_conf custom
    fi
    exec bash "$RICE/scripts/apps.sh" run editor "$custom"
    ;;
  preview)
    command -v fish >/dev/null 2>&1 || { echo "fish is not installed" >&2; exit 1; }
    exec fish -ic fish_greeting
    ;;
  *) echo "usage: greeting-conf.sh list | set LOGO <value> | paste | import FILE | edit | preview" >&2; exit 2 ;;
esac
