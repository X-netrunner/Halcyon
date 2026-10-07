#!/usr/bin/env bash
# ws-nav.sh next | prev | gesture-right | gesture-left | gesture4-right | gesture4-left | wheel-up | wheel-down      next / previous workspace, the way you would expect it to work
#
#   next   on the LAST workspace  ->  opens a brand new one   (1 2 -> 3).  An empty workspace never opens another
#                                     one after it, and the limit is Settings > Workspaces > "At most".
#   prev   on the FIRST workspace ->  jumps to the LAST one   (1 -> 2, or 3 when that is the highest).
#   anywhere else: the next / previous workspace that exists (empty ones in between are skipped).
#
# Used by the 3 / 4 finger swipes (hyprland/gestures.lua) and SUPER+CTRL+Right / Left (hyprland/keybinds.lua).
# Settings > Workspaces writes the one-line state files read here (~/.local/state/island/):
#   ws-end    new | wrap | stay     what "next" does on the last workspace   (default new)
#   ws-start  wrap | stay           what "previous" does on the first one    (default wrap)
#   ws-swipe4 left | right  which 4-finger swipe means "next" (default left); ignores ws-invert
#   ws-invert 0 | 1                 reverse the direction of swipes and the wheel (Settings > Workspaces > "Invert workspace scrolling")
#   ws-max    3..10                 highest workspace number "next" may create (default 9)
dir="${1:-next}"
# trace: which call arrived (tail -f ~/.cache/island/ws-nav.log while you swipe: no line = Hyprland never fired the gesture)
case "$dir" in gesture*) mkdir -p "$HOME/.cache/island"; echo "$(date +%T) $dir" >> "$HOME/.cache/island/ws-nav.log"; [ "$(wc -l < "$HOME/.cache/island/ws-nav.log")" -gt 200 ] && tail -n 50 "$HOME/.cache/island/ws-nav.log" > "$HOME/.cache/island/ws-nav.log.t" && mv "$HOME/.cache/island/ws-nav.log.t" "$HOME/.cache/island/ws-nav.log" ;; esac
state="$HOME/.local/state/island"
flag() { head -n1 "$state/$1" 2>/dev/null; }

# swipes and the wheel honour the "invert" option; plain next / prev (keybinds) never change
inv=$(flag ws-invert)
case "$dir" in
  gesture-right) dir=next ;;
  gesture-left)  dir=prev ;;
  gesture4-left)  dir=next; [ "$(flag ws-swipe4)" = right ] && dir=prev; inv=0 ;;
  gesture4-right) dir=prev; [ "$(flag ws-swipe4)" = right ] && dir=next; inv=0 ;;
  wheel-down)    dir=next ;;
  wheel-up)      dir=prev ;;
  *) inv=0 ;;
esac
if [ "$inv" = 1 ]; then [ "$dir" = next ] && dir=prev || dir=next; fi

end=$(flag ws-end);     case "$end" in new|wrap|stay) ;; *) end=new ;; esac
start=$(flag ws-start); case "$start" in wrap|stay) ;; *) start=wrap ;; esac
max=$(flag ws-max);     case "$max" in ''|*[!0-9]*) max=9 ;; esac
[ "$max" -lt 2 ] && max=2
[ "$max" -gt 10 ] && max=10

# every normal workspace that exists right now: "<id> <windows>" (special workspaces have negative ids)
declare -A wins=()
ids=()
while read -r id n; do
  [ -n "$id" ] || continue
  ids+=("$id"); wins[$id]=$n
done < <(hyprctl workspaces 2>/dev/null | awk '
  /^workspace ID/ { id = $3 }
  /^[ \t]*windows:/ { if (id + 0 > 0) print id, $2; id = 0 }')
[ "${#ids[@]}" -gt 0 ] || ids=(1)
mapfile -t ids < <(printf '%s\n' "${ids[@]}" | sort -n)

cur=$(hyprctl activeworkspace 2>/dev/null | awk 'NR == 1 { print $3 }')
case "$cur" in ''|*[!0-9]*) cur="${ids[0]}" ;; esac
[ "$cur" -gt 0 ] 2>/dev/null || cur="${ids[0]}"

first="${ids[0]}"
last="${ids[${#ids[@]}-1]}"
target=""

if [ "$dir" = "prev" ]; then
  for id in "${ids[@]}"; do [ "$id" -lt "$cur" ] && target="$id"; done        # the highest one below this one
  if [ -z "$target" ] && [ "$start" = "wrap" ] && [ "$last" -ne "$cur" ]; then target="$last"; fi
else
  for id in "${ids[@]}"; do if [ "$id" -gt "$cur" ]; then target="$id"; break; fi; done   # the lowest one above this one
  if [ -z "$target" ]; then
    case "$end" in
      new)
        # a new workspace only after one that has something on it, and never past the limit
        if [ "${wins[$cur]:-0}" -gt 0 ] && [ "$cur" -lt "$max" ]; then target=$((cur + 1))
        elif [ "$cur" -ge "$max" ] && [ "$first" -ne "$cur" ]; then target="$first"; fi ;;
      wrap) [ "$first" -ne "$cur" ] && target="$first" ;;
    esac
  fi
fi

[ -n "$target" ] && [ "$target" != "$cur" ] || exit 0
hyprctl dispatch "hl.dsp.focus({ workspace = $target })" >/dev/null 2>&1
exit 0
