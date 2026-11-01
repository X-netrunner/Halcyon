#!/usr/bin/env bash
# av-ai-idle.sh : the AI Antivirus analyzer (the local model that comments on alerts) only runs while the computer is idle.
#   av-ai-idle.sh active    you are at the computer: the analyzer is stopped (or left running when "Run it while idle only" is Off)
#   av-ai-idle.sh idle      nothing touched for a while: the analyzer starts and works through the alerts waiting for a comment
#   av-ai-idle.sh status    prints: off | working | waiting for idle
#   av-ai-idle.sh master off|on   the master AI switch changed (Settings > AI > AI features): off stops the analyzer at once and it stays
#                           stopped (idle no longer starts it); on gives it back to the idle rule above
# hypridle calls idle / active (scripts/idle.sh writes the listener; Settings > Sleep & lock sets the minutes). The antivirus itself
# keeps protecting the whole time: only the model's comments wait. Caffeine and video players that inhibit idle count as "at the computer".
# The root part is halcyon-tune (one sudo rule, no password): it starts the unit only when AI review is on and Gaming mode is not.
state="$HOME/.local/state/island"; envf="$state/idle.env"
AV_AI_IDLE=5
[ -f "$envf" ] && . "$envf"
case "$AV_AI_IDLE" in ''|*[!0-9]*) AV_AI_IDLE=5 ;; esac
tune=/usr/local/bin/halcyon-tune
unit=ai-antivirus-analyzer.service
ai_off() { [ -e "$state/ai-off" ]; }      # the master AI switch is off: no model is asked anything, the antivirus analyzer included

case "${1:-status}" in
  idle)   if ai_off; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; else sudo -n "$tune" av-ai resume >/dev/null 2>&1; fi ;;
  master) if [ "${2:-}" = off ]; then sudo -n "$tune" av-ai pause >/dev/null 2>&1
          elif [ "$AV_AI_IDLE" -gt 0 ]; then :                       # back on: it waits for the next idle period like before
          else sudo -n "$tune" av-ai resume >/dev/null 2>&1; fi ;;
  active) if ai_off; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; elif [ "$AV_AI_IDLE" -gt 0 ]; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; else sudo -n "$tune" av-ai resume >/dev/null 2>&1; fi ;;
  status) if ai_off; then echo off
          elif systemctl is-active --quiet "$unit"; then echo working
          elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then echo "waiting for idle"
          else echo off; fi ;;
  *) echo "usage: av-ai-idle.sh idle | active | status | master on|off" >&2; exit 2 ;;
esac
exit 0
