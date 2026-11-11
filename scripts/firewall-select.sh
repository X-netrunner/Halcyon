#!/usr/bin/env bash
# firewall-select.sh : switch ai-firewall on or off (Settings > Security > Firewall, and the Security center).
#   firewall-select.sh status     prints on | off (is the service running now)
#   firewall-select.sh on|off     asks for your admin password (sudo), so nothing can turn it off silently
# off: ai-firewall is stopped AND disabled (it stays installed with its config); `on` enables and starts it again.
# While it is off nothing refuses or bans incoming connections: turn it back on before joining an untrusted network.
set -u
UNIT=ai-firewall.service
active() { systemctl is-active --quiet "$UNIT"; }
status() { if active; then echo on; else echo off; fi; }
want="${1:-status}"
case "$want" in
  status) status; exit 0 ;;
  on|off) ;;
  *) echo "usage: firewall-select.sh status | on | off" >&2; exit 2 ;;
esac
systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "ai-firewall is not installed. Install it with: ./install.sh --firewall ai" >&2; exit 3; }
echo "Firewall: $(status) -> $want (your admin password is needed)"
sudo -v || { echo "Not changed." >&2; exit 1; }
case "$want" in
  on)  sudo systemctl enable --now "$UNIT" || { echo "ai-firewall did not start: journalctl -u ai-firewall -n 30" >&2; exit 1; } ;;
  off) sudo systemctl disable --now "$UNIT" || { echo "ai-firewall did not stop" >&2; exit 1; } ;;
esac
echo "Firewall is now: $(status)"
