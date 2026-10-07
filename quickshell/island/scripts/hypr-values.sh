#!/usr/bin/env bash
# The Hyprland values Settings can change, as they are right now (one line of JSON). Settings shows them as the starting
# position of its sliders, so nothing jumps and nothing is pushed until you actually change it.
#   {"borderSize":2,"activeOpacity":1,"inactiveOpacity":1, ... "accelProfile":"adaptive","layout":"dwindle"}
declare -a out=()
get() {   # get <json key> <hyprland option>
  local raw
  raw=$(timeout 2 hyprctl -j getoption "$2" 2>/dev/null) || return
  local num str
  num=$(printf '%s' "$raw" | sed -n 's/.*"\(int\|float\)": *\(-\?[0-9][0-9.]*\).*/\2/p' | head -n1)
  if [ -n "$num" ]; then
    # 1.000000 -> 1 ; 0.900000 -> 0.9
    case "$num" in *.*) num=$(printf '%s' "$num" | sed 's/0*$//; s/\.$//') ;; esac
    out+=("\"$1\":$num")
    return
  fi
  str=$(printf '%s' "$raw" | sed -n 's/.*"str": *"\([^"]*\)".*/\1/p' | head -n1)
  [ -n "$str" ] && out+=("\"$1\":\"$str\"")
}
get borderSize       general:border_size
get resizeOnBorder   general:resize_on_border
get layout           general:layout
get activeOpacity    decoration:active_opacity
get inactiveOpacity  decoration:inactive_opacity
get dimInactive      decoration:dim_inactive
get dimStrength      decoration:dim_strength
get blurSize         decoration:blur:size
get blurPasses       decoration:blur:passes
get followMouse      input:follow_mouse
get repeatDelay      input:repeat_delay
get repeatRate       input:repeat_rate
get sensitivity      input:sensitivity
get accelProfile     input:accel_profile
get leftHanded       input:left_handed
get naturalScroll    input:touchpad:natural_scroll
get tapToClick       input:touchpad:tap_to_click
get disableTyping    input:touchpad:disable_while_typing
get focusOnActivate  misc:focus_on_activate
( IFS=,; printf '{%s}\n' "${out[*]}" )
