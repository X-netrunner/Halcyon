#!/usr/bin/env bash
# av-ai-idle.sh : the AI Antivirus analyzer (the local model that comments on alerts) only runs while the computer is idle.
#   av-ai-idle.sh active    you are at the computer: the analyzer is stopped (or left running when "Run it while idle only" is Off)
#   av-ai-idle.sh idle      nothing touched for a while: the analyzer starts and works through the alerts waiting for a comment
#   av-ai-idle.sh status    prints: off | working | waiting for idle
# hypridle calls idle / active (scripts/idle.sh writes the listener; Settings > Sleep & lock sets the minutes). The antivirus itself
# keeps protecting the whole time: only the model's comments wait. Caffeine and video players that inhibit idle count as "at the computer".
# The root part is halcyon-tune (one sudo rule, no password): it starts the unit only when AI review is on and Gaming mode is not.
state="$HOME/.local/state/island"; envf="$state/idle.env"
AV_AI_IDLE=5
[ -f "$envf" ] && . "$envf"
case "$AV_AI_IDLE" in ''|*[!0-9]*) AV_AI_IDLE=5 ;; esac
tune=/usr/local/bin/halcyon-tune
unit=ai-antivirus-analyzer.service

case "${1:-status}" in
  idle)   sudo -n "$tune" av-ai resume >/dev/null 2>&1 ;;
  active) if [ "$AV_AI_IDLE" -gt 0 ]; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; else sudo -n "$tune" av-ai resume >/dev/null 2>&1; fi ;;
  status) if systemctl is-active --quiet "$unit"; then echo working
          elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then echo "waiting for idle"
          else echo off; fi ;;
  *) echo "usage: av-ai-idle.sh idle | active | status" >&2; exit 2 ;;
esac
exit 0
