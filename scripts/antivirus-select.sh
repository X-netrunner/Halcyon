#!/usr/bin/env bash
# antivirus-select.sh : which antivirus runs (Settings > Security > Antivirus).
#   antivirus-select.sh status            prints ai | clamav | off (what runs now)
#   antivirus-select.sh ai|clamav|off     switches; asks for your admin password (sudo), so nothing can turn it off silently
# ai      AI Antivirus (ai-antivirus-sensord, -engined, -responderd; the analyzer too when [ai] enabled = true; your notifier)
# clamav  ClamAV: signature updates (clamav-freshclam), the scan daemon (clamav-daemon), and on-access scanning
#         (clamav-clamonacc) only when /etc/clamav/clamd.conf names folders to watch (OnAccessIncludePath)
# off     both stopped and disabled. The packages and their settings stay; choose one again to turn it back on.
# Only one runs at a time. The firewall is not touched.
set -u
AI_UNITS=(ai-antivirus-sensord.service ai-antivirus-engined.service ai-antivirus-responderd.service)
AI_ANALYZER=ai-antivirus-analyzer.service
CLAM_UNITS=(clamav-freshclam.service clamav-daemon.service)
CLAM_ONACC=clamav-clamonacc.service
AV_CONF=/etc/ai-antivirus/ai-antivirus.toml

have_unit() { systemctl cat "$1" >/dev/null 2>&1; }
active() { systemctl is-active --quiet "$1"; }

status() {
  if active ai-antivirus-engined.service || active ai-antivirus-sensord.service; then echo ai
  elif active clamav-daemon.service || active clamav-clamonacc.service; then echo clamav
  else echo off
  fi
}

# [ai] enabled = true in the AI Antivirus config (the analyzer only runs then)
analyzer_wanted() {
  [ -r "$AV_CONF" ] || return 1
  awk '/^\[/{s=$0} s=="[ai]" && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true/{f=1} END{exit !f}' "$AV_CONF"
}
onacc_wanted() { grep -qE '^[[:space:]]*OnAccessIncludePath[[:space:]]+/' /etc/clamav/clamd.conf 2>/dev/null; }

ai_units_present() { local u; for u in "${AI_UNITS[@]}"; do have_unit "$u" || return 1; done; }
clam_units_present() { local u; for u in "${CLAM_UNITS[@]}"; do have_unit "$u" || return 1; done; }

# the units of the one that is NOT chosen, if installed
stop_ai() {
  ai_units_present || return 0
  sudo systemctl disable --now "${AI_UNITS[@]}" "$AI_ANALYZER" 2>/dev/null
  systemctl --user disable --now ai-antivirus-notify.service >/dev/null 2>&1 || true
}
stop_clam() {
  local u list=()
  for u in "${CLAM_UNITS[@]}" "$CLAM_ONACC"; do have_unit "$u" && list+=("$u"); done
  [ ${#list[@]} -gt 0 ] && sudo systemctl disable --now "${list[@]}" 2>/dev/null
  return 0
}

want="${1:-status}"
case "$want" in
  status) status; exit 0 ;;
  ai|clamav|off) ;;
  *) echo "usage: antivirus-select.sh status | ai | clamav | off" >&2; exit 2 ;;
esac

if [ "$want" = ai ] && ! ai_units_present; then
  echo "AI Antivirus is not installed. Install it with: ./install.sh --antivirus" >&2; exit 3
fi
if [ "$want" = clamav ] && ! clam_units_present; then
  echo "ClamAV is not installed (sudo pacman -S clamav)." >&2; exit 3
fi

echo "Antivirus: $(status) -> $want (your admin password is needed)"
sudo -v || { echo "Not changed." >&2; exit 1; }

case "$want" in
  ai)
    stop_clam
    units=("${AI_UNITS[@]}")
    analyzer_wanted && units+=("$AI_ANALYZER")
    sudo systemctl enable --now "${units[@]}" || { echo "AI Antivirus did not start: journalctl -u ai-antivirus-engined" >&2; exit 1; }
    systemctl --user enable --now ai-antivirus-notify.service >/dev/null 2>&1 || true
    ;;
  clamav)
    stop_ai
    units=("${CLAM_UNITS[@]}")
    onacc_wanted && have_unit "$CLAM_ONACC" && units+=("$CLAM_ONACC")
    # the daemon refuses to start without signatures: fetch them once first
    [ -n "$(ls /var/lib/clamav/*.c[lv]d 2>/dev/null)" ] || sudo freshclam --quiet || true
    sudo systemctl enable --now "${units[@]}" || { echo "ClamAV did not start: journalctl -u clamav-daemon" >&2; exit 1; }
    ;;
  off)
    stop_ai
    stop_clam
    ;;
esac
echo "Antivirus is now: $(status)"
