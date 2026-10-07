#!/usr/bin/env bash
# Select the power manager: halcyon | power-profiles-daemon | tlp | auto-cpufreq | tuned
# Only one of them may control the CPU, so the others are stopped (via the sudo helper halcyon-tune).
MGR="${1:-halcyon}"
QUIET="${2:-}"      # "quiet": no "now using ..." popup (the island passes it at login, when it only re-applies your choice)
STATE_DIR="$HOME/.local/state/island"; mkdir -p "$STATE_DIR"
note() { command -v notify-send >/dev/null && notify-send -a Halcyon -i battery "Power manager" "$1" -h string:x-canonical-private-synchronous:powermanager; }

declare -A BIN=( [power-profiles-daemon]=powerprofilesctl [tlp]=tlp [auto-cpufreq]=auto-cpufreq [tuned]=tuned-adm )
if [ -n "${BIN[$MGR]}" ] && ! command -v "${BIN[$MGR]}" >/dev/null 2>&1; then
  note "$MGR is not installed. Install it first (pacman -S $MGR), the previous manager stays active."
  exit 1
fi

if ! timeout 20 sudo -n /usr/local/bin/halcyon-tune pm "$MGR" 2>"$STATE_DIR/pm-error"; then
  note "Could not switch to $MGR: $(tail -1 "$STATE_DIR/pm-error" 2>/dev/null || echo 'run install.sh again to set up halcyon-tune')"
  exit 1
fi
echo "$MGR" > "$STATE_DIR/power-manager"

if [ "$MGR" = halcyon ]; then
  systemctl --user start power-manager.service 2>/dev/null; [ "$QUIET" = quiet ] || note "Halcyon Auto power is on"
else
  systemctl --user stop power-manager.service 2>/dev/null; [ "$QUIET" = quiet ] || note "Now using $MGR (Halcyon Auto stopped)"
fi
