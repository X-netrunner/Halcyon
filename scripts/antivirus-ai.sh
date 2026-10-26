#!/usr/bin/env bash
# antivirus-ai.sh : AI review of antivirus alerts (Settings > Security, Security center > Antivirus).
#   antivirus-ai.sh status        prints: on | off, and the model it would use
#   antivirus-ai.sh on | off      switches; asks for your admin password (sudo): the setting lives in /etc/ai-antivirus/ai-antivirus.toml
# What it is: ai-antivirus has an analyzer that sends each alert at or above `min_severity` to a LOCAL Ollama model (loopback only,
# at most `max_per_hour` a time) and keeps its comments, advice only: it never blocks or deletes anything by itself.
# Turning it on sets [ai] enabled = true, checks that the model is installed (offers to pull it), and starts ai-antivirus-analyzer.service
# when ai-antivirus is the antivirus that runs. Turning it off does the reverse. Nothing else in the config is touched.
set -u
CONF=/etc/ai-antivirus/ai-antivirus.toml
UNIT=ai-antivirus-analyzer.service

command -v ai-antivirus >/dev/null 2>&1 && [ -r "$CONF" ] || { echo "AI Antivirus is not installed. Install it with: ./install.sh --antivirus" >&2; exit 3; }

ai_value() {   # ai_value KEY: the value of KEY in the [ai] section, quotes removed
  awk -v k="$1" '/^\[/{s=$0} s=="[ai]" && $1==k {sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/[\x27"]/, ""); print; exit}' "$CONF"
}
is_on() { [ "$(ai_value enabled)" = true ]; }
model() { ai_value model; }

want="${1:-status}"
case "$want" in
  status) if is_on; then echo "on  (model $(model))"; else echo "off  (model $(model))"; fi; exit 0 ;;
  on|off) ;;
  *) echo "usage: antivirus-ai.sh status | on | off" >&2; exit 2 ;;
esac

set_enabled() { sudo sed -i "/^\[ai\]/,/^\[/ s|^enabled *=.*|enabled = $1|" "$CONF"; }
av_runs() { systemctl is-active --quiet ai-antivirus-engined.service; }

if [ "$want" = on ]; then
  m=$(model)
  if command -v ollama >/dev/null 2>&1; then
    if ! ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -e "$m" -e "$m:latest"; then
      echo "The model '$m' is not installed in Ollama."
      read -r -p "Download it now (ollama pull $m)? [y/N] " a
      case "$a" in y|Y) ollama pull "$m" || { echo "Could not download $m. Not changed." >&2; exit 1; } ;;
                   *) echo "Not changed. The analyzer needs $m (change it in $CONF under [ai])." >&2; exit 1 ;; esac
    fi
  else
    echo "Ollama is not installed, so there is no model to ask. Not changed." >&2; exit 1
  fi
  echo "AI review of alerts: on (model $m). Your admin password is needed."
  sudo -v || { echo "Not changed." >&2; exit 1; }
  set_enabled true
  if av_runs; then sudo systemctl enable --now "$UNIT" || { echo "The analyzer did not start: journalctl -u ai-antivirus-analyzer" >&2; exit 1; }
  else echo "ai-antivirus is not the running antivirus right now; the analyzer starts with it."; fi
else
  echo "AI review of alerts: off. Your admin password is needed."
  sudo -v || { echo "Not changed." >&2; exit 1; }
  set_enabled false
  sudo systemctl disable --now "$UNIT" 2>/dev/null || true
fi
if is_on; then echo "AI review of alerts is now: on"; else echo "AI review of alerts is now: off"; fi
