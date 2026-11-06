#!/usr/bin/env bash
# av-ai-watch.sh : starts the AI Antivirus analyzer (the local model that comments on alerts) when a NEW alert arrives, instead of
# waiting for the computer to sit idle. Active only in the mode "On alert" (Settings > Security; AV_AI_IDLE=99 in idle.env, the default).
#   - every POLL seconds it reads `ai-antivirus status --json` (a few KB, no model involved)
#   - a new alert (alerts_24h or unacked went up) starts the analyzer through av-ai-idle.sh run -> halcyon-tune (the one sudo rule)
#   - if the machine is busy (load), on a low battery, or Gaming mode is on, the alert stays pending and is tried again next poll
#   - HOLD seconds after the last new alert the analyzer is stopped again, so the model is not kept loaded for nothing
# The antivirus itself keeps protecting the whole time; only the model's comments wait. One copy only (flock).
set -u
state="$HOME/.local/state/island"; envf="$state/idle.env"
here="$(dirname "$(readlink -f "$0")")"
POLL=20; HOLD=240; MAXLOAD=70; MINBAT=25
mkdir -p "$state"
exec 9>"$state/av-ai-watch.lock"; flock -n 9 || exit 0

mode() { local v=99; [ -f "$envf" ] && v=$(sed -n 's/^AV_AI_IDLE=\([0-9]*\)$/\1/p' "$envf" | tail -1); echo "${v:-99}"; }
num() { sed -n "s/.*\"$1\" *: *\([0-9][0-9]*\).*/\1/p" <<<"$2" | head -1; }
status() {
  local j; j=$(timeout 8 ai-antivirus status --json 2>/dev/null)
  if [ -z "$j" ] || grep -q '"db_readable" *: *false' <<<"$j"; then   # group not known to this session yet: read it through sg
    j=$(timeout 8 sg ai-antivirus -c "ai-antivirus status --json" 2>/dev/null) || true
  fi
  printf '%s' "$j"
}
busy() {   # 1-minute load above MAXLOAD % of the cores
  local l n; read -r l _ < /proc/loadavg; n=$(nproc 2>/dev/null || echo 1)
  awk -v l="$l" -v n="$n" -v m="$MAXLOAD" 'BEGIN{exit !(l*100 > n*m)}'
}
low_battery() {
  local b st cap
  for b in /sys/class/power_supply/BAT*; do
    [ -r "$b/capacity" ] || continue
    st=$(cat "$b/status" 2>/dev/null); cap=$(cat "$b/capacity" 2>/dev/null)
    [ "$st" = Discharging ] && [ "${cap:-100}" -lt "$MINBAT" ] && return 0
  done
  return 1
}

last_a=-1; last_u=-1; pending=0; last_alert=0; running=0
while :; do
  if [ "$(mode)" != 99 ] || [ -e "$state/ai-off" ] || ! command -v ai-antivirus >/dev/null 2>&1; then
    sleep 60; last_a=-1; last_u=-1; pending=0; continue
  fi
  now=$(date +%s)
  j=$(status); a=$(num alerts_24h "$j"); u=$(num unacked "$j"); a=${a:-0}; u=${u:-0}
  if [ -n "$j" ]; then
    if [ "$last_a" -lt 0 ]; then
      [ "$u" -gt 0 ] && pending=1                      # first look after login: alerts already waiting get their comment too
    elif [ "$a" -gt "$last_a" ] || [ "$u" -gt "$last_u" ]; then
      pending=1; last_alert=$now
    fi
    last_a=$a; last_u=$u
  fi
  if [ "$pending" = 1 ]; then
    if busy || low_battery; then :                     # not now: still pending, tried again at the next poll
    else bash "$here/av-ai-idle.sh" run >/dev/null 2>&1; pending=0; running=1; last_alert=$now; fi
  elif [ "$running" = 1 ] && [ $((now - last_alert)) -ge "$HOLD" ]; then
    bash "$here/av-ai-idle.sh" stop >/dev/null 2>&1; running=0
  fi
  sleep "$POLL"
done
