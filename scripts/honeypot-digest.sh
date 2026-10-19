#!/usr/bin/env bash
# honeypot-digest.sh: one quiet notification a day (instead of one per probe) about what the sysmode honeypot saw.
#
#   honeypot-digest.sh [--print] [--hours N]   summarize the last N hours (default 24); --print writes it to the terminal
#                                              instead of sending a notification. Nothing happened = no notification.
#   honeypot-digest.sh enable                  switch the daily digest on (a systemd user timer, 09:00)
#   honeypot-digest.sh disable                 switch it off
#
# Reads recon-attempts.log from /var/log/halcyon (the daemon's log; override with HALCYON_LOGS). Lines look like
# "[2026-10-19 08:12:03] [ALERT] ...". Your own gateway / DNS / machine ("Not banning ...") are left out of the top list.
set -uo pipefail

RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
LOGDIR="${HALCYON_LOGS:-/var/log/halcyon}"
UNITS="$HOME/.config/systemd/user"

case "${1:-}" in
  enable)
    [ -f "$RICE/systemd/honeypot-digest.timer" ] || { echo "honeypot-digest: $RICE/systemd/honeypot-digest.timer not found" >&2; exit 1; }
    mkdir -p "$UNITS"
    cp "$RICE/systemd/honeypot-digest.service" "$RICE/systemd/honeypot-digest.timer" "$UNITS/" || exit 1
    systemctl --user daemon-reload && systemctl --user enable --now honeypot-digest.timer && echo "Daily honeypot digest is on (09:00)."
    exit $? ;;
  disable)
    systemctl --user disable --now honeypot-digest.timer 2>/dev/null; rm -f "$UNITS/honeypot-digest.timer" "$UNITS/honeypot-digest.service"
    systemctl --user daemon-reload 2>/dev/null; echo "Daily honeypot digest is off."; exit 0 ;;
esac

PRINT=0; HOURS=24
while [ $# -gt 0 ]; do
  case "$1" in
    --print) PRINT=1 ;;
    --hours) shift; HOURS="${1:-24}" ;;
    -h|--help) sed -n 2,10p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "honeypot-digest: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
case "$HOURS" in ''|*[!0-9]*) echo "honeypot-digest: --hours needs a number" >&2; exit 2 ;; esac

LOG="$LOGDIR/recon-attempts.log"
[ -r "$LOG" ] || { [ "$PRINT" = 1 ] && echo "No readable honeypot log at $LOG (is sysmode installed and the decoy running?)"; exit 0; }
CUTOFF="$(date -d "$HOURS hours ago" '+%Y-%m-%d %H:%M:%S')"

# timestamps are fixed-width, so a plain string comparison is a time comparison
SUMMARY="$(awk -v cut="$CUTOFF" '
  substr($0,1,1) == "[" && substr($0,2,19) >= cut {
    n++
    if ($0 ~ /\[ALERT\]/) alerts++
    if ($0 ~ /Banning IP/) bans++
    if ($0 ~ /Not banning/) next
    if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) { ip = substr($0, RSTART, RLENGTH); hits[ip]++ }
    if (match($0, /[Pp]ort [0-9]+/)) { p = substr($0, RSTART + 5, RLENGTH - 5); ports[p]++ }
  }
  END {
    nip = 0; for (i in hits) nip++
    printf "events %d\nalerts %d\nbans %d\nips %d\n", n, alerts, bans, nip
    for (i in hits)  printf "ip %s %d\n", i, hits[i]
    for (p in ports) printf "port %s %d\n", p, ports[p]
  }' "$LOG")"

get() { awk -v k="$1" '$1==k {print $2}' <<<"$SUMMARY"; }
EVENTS="$(get events)"; ALERTS="$(get alerts)"; BANS="$(get bans)"; IPS="$(get ips)"
[ "${EVENTS:-0}" -gt 0 ] || { [ "$PRINT" = 1 ] && echo "Honeypot: nothing in the last $HOURS h."; exit 0; }

TOPIPS="$(awk '$1=="ip"{print $3, $2}' <<<"$SUMMARY" | sort -rn | head -5 | awk '{printf "%s%s (%s)", (NR>1?", ":""), $2, $1}')"
TOPPORTS="$(awk '$1=="port"{print $3, $2}' <<<"$SUMMARY" | sort -rn | head -5 | awk '{printf "%s%s (%s)", (NR>1?", ":""), $2, $1}')"

BODY="${IPS:-0} host(s), ${EVENTS} events, ${ALERTS:-0} alerts, ${BANS:-0} banned"
[ -n "$TOPIPS" ] && BODY="$BODY"$'\n'"Busiest: $TOPIPS"
[ -n "$TOPPORTS" ] && BODY="$BODY"$'\n'"Ports: $TOPPORTS"

if [ "$PRINT" = 1 ] || ! command -v notify-send >/dev/null 2>&1; then
  printf 'Honeypot, last %s h\n%s\n' "$HOURS" "$BODY"
else
  notify-send -a Halcyon -i security-medium "Honeypot, last $HOURS h" "$BODY"
fi
