#!/usr/bin/env bash
# halcyon-mem.sh : what Halcyon really costs in RAM. Run it before and after a change (same apps open, a minute after login).
# RSS counts shared library pages in every process that maps them; PSS splits those fairly, so PSS is the honest number.
printf '%-22s %6s %9s %9s\n' process pid 'RSS MB' 'PSS MB'
tp=0; tr=0
show() {   # label pid
  local pid=$2 rss pss
  rss=$(awk '/^VmRSS:/{print int($2/1024)}' /proc/$pid/status 2>/dev/null)
  pss=$(awk '/^Pss:/{s+=$2} END{print int(s/1024)}' /proc/$pid/smaps_rollup 2>/dev/null)
  [ -n "$rss" ] || return
  printf '%-22s %6s %9s %9s\n' "$1" "$pid" "$rss" "${pss:-?}"
  tp=$((tp + ${pss:-0})); tr=$((tr + rss))
}
for pid in $(pgrep -x Hyprland);                  do show Hyprland "$pid"; done
for pid in $(pgrep -x quickshell; pgrep -x qs);   do show "quickshell($(tr '\0' ' ' < /proc/$pid/cmdline | sed 's/.*quickshell\///;s/ .*//'))" "$pid"; done
for n in hx power-manager touchpad-gestures cava hypridle wl-paste polkit-kde-authent nm-applet blueman-applet; do
  for pid in $(pgrep -f "(^|/)$n( |$)" 2>/dev/null | head -n 4); do show "$n" "$pid"; done
done
printf '%-22s %6s %9s %9s\n' TOTAL '' "$tr" "$tp"
