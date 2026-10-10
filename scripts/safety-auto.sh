#!/usr/bin/env bash
# safety-auto.sh : run the safety check by itself every N days (Settings > Backup > Safety check > "Run it automatically").
#   safety-auto.sh on DAYS USER    install the timer (needs root: Settings asks for your sudo password first)
#   safety-auto.sh off             remove it again (needs root as well)
# It is locked behind sudo on purpose: the run itself is root, so only someone who knows the password can switch it on, change
# how often it runs, or switch it off. What runs as root is only root-owned: /usr/local/bin/safety-check and a small wrapper this
# script writes to /usr/local/bin (never a file in your home folder).
# An automatic run: never updates the system, never asks questions and never formats a disk (safety-check --auto);
# the backup step only happens when the known backup disk is plugged in. It waits for AC power and runs at low priority.
set -u
unit_s=/etc/systemd/system/halcyon-safety-check.service
unit_t=/etc/systemd/system/halcyon-safety-check.timer
wrap=/usr/local/bin/halcyon-safety-auto-run

[ "$(id -u)" = 0 ] || { echo "needs root (sudo)" >&2; exit 1; }
case "${1:-}" in
  on)
    days="${2:-}"; user="${3:-}"
    case "$days" in ''|*[!0-9]*) echo "DAYS must be a number" >&2; exit 2 ;; esac
    [ "$days" -ge 1 ] && [ "$days" -le 365 ] || { echo "DAYS must be 1..365" >&2; exit 2; }
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] && id -u "$user" >/dev/null 2>&1 && [ "$user" != root ] || { echo "bad user" >&2; exit 2; }
    [ -x /usr/local/bin/safety-check ] || { echo "the safety check is not installed (./install.sh --safety-check)" >&2; exit 3; }
    [ "$(stat -c %u /usr/local/bin/safety-check)" = 0 ] || { echo "/usr/local/bin/safety-check is not owned by root: refusing" >&2; exit 3; }
    command -v systemctl >/dev/null 2>&1 || { echo "systemd is needed for the timer" >&2; exit 3; }
    tmp=$(mktemp) || exit 1
    cat > "$tmp" <<WRAP
#!/bin/sh
# written by Halcyon scripts/safety-auto.sh (root-owned on purpose: it runs as root). Remove with: sudo safety-auto.sh off
DAYS=$days
SUDO_USER=$user
export SUDO_USER
last=\$(cat /var/lib/halcyon/safety-last-run 2>/dev/null || echo 0)
now=\$(date +%s)
[ \$((now - last)) -ge \$((DAYS * 86400 - 7200)) ] || exit 0          # not due yet
bat=0; ac=0
for d in /sys/class/power_supply/*; do
  [ -r "\$d/type" ] || continue
  case "\$(cat "\$d/type")" in Battery) bat=1 ;; Mains) [ "\$(cat "\$d/online" 2>/dev/null)" = 1 ] && ac=1 ;; esac
done
[ "\$bat" = 0 ] || [ "\$ac" = 1 ] || exit 0                          # on battery: try again at the next look (every 6 hours)
/usr/local/bin/safety-check --auto </dev/null || exit \$?
mkdir -p /var/lib/halcyon && echo "\$now" > /var/lib/halcyon/safety-last-run && chmod 644 /var/lib/halcyon/safety-last-run
WRAP
    install -m755 -o root -g root "$tmp" "$wrap" && rm -f "$tmp"
    cat > "$unit_s" <<UNIT
# halcyon-days=$days
[Unit]
Description=Halcyon safety check (automatic run, every $days day(s))

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=$wrap
UNIT
    cat > "$unit_t" <<UNIT
[Unit]
Description=Halcyon safety check: look every 6 hours whether a run is due

[Timer]
OnCalendar=*-*-* 0/6:15:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    chmod 644 "$unit_s" "$unit_t"
    systemctl daemon-reload && systemctl enable --now halcyon-safety-check.timer >/dev/null 2>&1 || { echo "could not start the timer" >&2; exit 4; }
    echo "automatic safety check: on, every $days day(s)" ;;
  off)
    systemctl disable --now halcyon-safety-check.timer >/dev/null 2>&1
    rm -f "$unit_s" "$unit_t" "$wrap"
    systemctl daemon-reload
    echo "automatic safety check: off" ;;
  *) echo "usage: sudo safety-auto.sh on DAYS USER | off" >&2; exit 2 ;;
esac
