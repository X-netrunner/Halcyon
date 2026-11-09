#!/usr/bin/env bash
# av-ai-idle.sh : the AI Antivirus analyzer (the local model that comments on alerts) only runs while the computer is idle.
#   av-ai-idle.sh active    you are at the computer: the analyzer is stopped (or left running when "Run it while idle only" is Off)
#   av-ai-idle.sh idle      nothing touched for a while: the analyzer starts and works through the alerts waiting for a comment
#   av-ai-idle.sh status    prints: off | working | waiting for idle
#   av-ai-idle.sh master off|on   the master AI switch changed (Settings > AI > AI features): off stops the analyzer at once and it stays
#                           stopped (idle no longer starts it); on gives it back to the idle rule above
# hypridle calls idle / active (scripts/idle.sh writes the listener; Settings > Sleep & lock sets the minutes). The antivirus itself
# keeps protecting the whole time: only the model's comments wait. Caffeine and video players that inhibit idle count as "at the computer".
# "On alert" (AV_AI_IDLE=99, the default): no idle timer at all. scripts/av-ai-watch.sh starts the analyzer when a NEW alert arrives and
# stops it a few minutes after the last one, so the model works when there is something to comment on, however busy you are.
#   av-ai-idle.sh run       start the analyzer now (used by av-ai-watch.sh)      av-ai-idle.sh stop   pause it again
# The root part is halcyon-tune (one sudo rule, no password): it starts the unit only when AI review is on and Gaming mode is not.
state="$HOME/.local/state/island"; envf="$state/idle.env"
AV_AI_IDLE=99
[ -f "$envf" ] && . "$envf"
case "$AV_AI_IDLE" in ''|*[!0-9]*) AV_AI_IDLE=99 ;; esac
alert_mode() { [ "$AV_AI_IDLE" -eq 99 ]; }
tune=/usr/local/bin/halcyon-tune
unit=ai-antivirus-analyzer.service
ai_off() { [ -e "$state/ai-off" ]; }
# The analyzer's model (Settings > Security > AI Antivirus comments uses the one in ai-antivirus.toml [ai]) stays in Ollama's memory for
# Ollama's own keep-alive after the unit stops (5 minutes by default, 2 to 3 GB). Stopping the unit now also lets the model go at once.
unload_model() {
  local m h
  m=$(awk '/^\[/{s=$0} s=="[ai]" && $1=="model" {sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/[\x27"]/, ""); print; exit}' /etc/ai-antivirus/ai-antivirus.toml 2>/dev/null | tr -cd 'A-Za-z0-9._:/-')
  [ -n "$m" ] || return 0
  h="${OLLAMA_HOST:-127.0.0.1:11434}"; case "$h" in http*) ;; *) h="http://$h" ;; esac
  command -v curl >/dev/null 2>&1 || return 0
  ( timeout 6 curl -fsS "$h/api/generate" -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null 2>&1 & ) 2>/dev/null
}      # the master AI switch is off: no model is asked anything, the antivirus analyzer included

case "${1:-status}" in
  idle)   if ai_off; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; else sudo -n "$tune" av-ai resume >/dev/null 2>&1; fi ;;
  run)    ai_off || sudo -n "$tune" av-ai resume >/dev/null 2>&1 ;;
  stop)   sudo -n "$tune" av-ai pause >/dev/null 2>&1; unload_model ;;
  master) if [ "${2:-}" = off ]; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; unload_model
          elif [ "$AV_AI_IDLE" -gt 0 ]; then :                       # back on: it waits for the next idle period like before
          else sudo -n "$tune" av-ai resume >/dev/null 2>&1; fi ;;
  active) if ai_off; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; elif alert_mode; then :      # a run started by an alert is not cut short by a key press
          elif [ "$AV_AI_IDLE" -gt 0 ]; then sudo -n "$tune" av-ai pause >/dev/null 2>&1; else sudo -n "$tune" av-ai resume >/dev/null 2>&1; fi ;;
  status) if ai_off; then echo off
          elif systemctl is-active --quiet "$unit"; then echo working
          elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then if alert_mode; then echo "waiting for an alert"; else echo "waiting for idle"; fi
          else echo off; fi ;;
  *) echo "usage: av-ai-idle.sh idle | active | run | stop | status | master on|off" >&2; exit 2 ;;
esac
exit 0
