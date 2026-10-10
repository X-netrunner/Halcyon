#!/usr/bin/env bash
# remind.sh : "remind me to back up / run the safety check" (Settings > Backup).
#   remind.sh conf                 one line of JSON for Settings: the choices, when each last happened, and the automatic safety-check run
#   remind.sh set KEY VALUE        BACKUP_REMIND | SAFETY_REMIND  0|1      BACKUP_EVERY | SAFETY_EVERY  1|7|30|90|custom      BACKUP_DAYS | SAFETY_DAYS  1..365 (used by "custom")
#   remind.sh check                what the timer runs: one notification for each reminder that is due (nothing else)
#   remind.sh done backup|safety   note that it just happened (backup-device.sh and the Settings safety-check button call this)
#   remind.sh status               the same as plain text
# Choices: ~/.config/Halcyon/remind.conf. Times: ~/.local/state/island/remind/. The timer (halcyon-remind.timer, a user unit)
# is only switched on while at least one reminder is on, so nothing runs in the background when you want none.
# The AUTOMATIC safety-check run is a different thing (it needs root): scripts/safety-auto.sh, behind your sudo password.
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
conf="$RICE/remind.conf"
sdir="$HOME/.local/state/island/remind"
auto_stamp=/var/lib/halcyon/safety-last-run          # written by the root timer after each automatic run (world-readable)
auto_service=/etc/systemd/system/halcyon-safety-check.service
auto_timer=/etc/systemd/system/halcyon-safety-check.timer

BACKUP_REMIND=0; BACKUP_EVERY=7;  BACKUP_DAYS=14
SAFETY_REMIND=0; SAFETY_EVERY=30; SAFETY_DAYS=14
[ -f "$conf" ] && . "$conf" 2>/dev/null

num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
clampdays() { local d; d=$(num "$1" 14); [ "$d" -lt 1 ] && d=1; [ "$d" -gt 365 ] && d=365; echo "$d"; }
every_ok() { case "$1" in 1|7|30|90|custom) echo "$1" ;; *) echo "$2" ;; esac; }
BACKUP_EVERY=$(every_ok "$BACKUP_EVERY" 7);  SAFETY_EVERY=$(every_ok "$SAFETY_EVERY" 30)
BACKUP_DAYS=$(clampdays "$BACKUP_DAYS");     SAFETY_DAYS=$(clampdays "$SAFETY_DAYS")
[ "$BACKUP_REMIND" = 1 ] || BACKUP_REMIND=0; [ "$SAFETY_REMIND" = 1 ] || SAFETY_REMIND=0

write_conf() {
  mkdir -p "$(dirname "$conf")"
  local tmp; tmp=$(mktemp) || return 1
  { printf 'BACKUP_REMIND=%s\nBACKUP_EVERY=%s\nBACKUP_DAYS=%s\nSAFETY_REMIND=%s\nSAFETY_EVERY=%s\nSAFETY_DAYS=%s\n' \
      "$BACKUP_REMIND" "$BACKUP_EVERY" "$BACKUP_DAYS" "$SAFETY_REMIND" "$SAFETY_EVERY" "$SAFETY_DAYS"
    if [ -f "$conf" ]; then grep -v -E '^(BACKUP|SAFETY)_(REMIND|EVERY|DAYS)=' "$conf" || true; fi
  } > "$tmp" && mv "$tmp" "$conf"
}

now() { printf '%(%s)T' -1; }
stamp() { local v=0; [ -r "$1" ] && read -r v < "$1" 2>/dev/null; num "$v" 0; }       # a file with one epoch number, 0 = never
days_of() { case "$1" in backup) [ "$BACKUP_EVERY" = custom ] && echo "$BACKUP_DAYS" || echo "$BACKUP_EVERY" ;;
                         safety) [ "$SAFETY_EVERY" = custom ] && echo "$SAFETY_DAYS" || echo "$SAFETY_EVERY" ;; esac; }
last_done() {   # backup | safety  ->  epoch of the last time it ran (the automatic safety-check run counts too)
  local a b; a=$(stamp "$sdir/last-$1")
  if [ "$1" = safety ]; then b=$(stamp "$auto_stamp"); [ "$b" -gt "$a" ] && a=$b; fi
  echo "$a"
}
ago() {   # epoch -> "never" / "today" / "3 days ago"
  local t=$1 d
  [ "$t" -gt 0 ] || { echo never; return; }
  d=$(( ( $(now) - t ) / 86400 ))
  case "$d" in 0) echo today ;; 1) echo "1 day ago" ;; *) echo "$d days ago" ;; esac
}

auto_on() { [ -f "$auto_timer" ] && systemctl is-enabled --quiet halcyon-safety-check.timer 2>/dev/null; }
auto_days() { local d=0; [ -r "$auto_service" ] && d=$(sed -n 's/^# halcyon-days=\([0-9]*\).*/\1/p' "$auto_service" | head -n1); num "$d" 0; }

sync_timer() {   # the reminder timer runs only while a reminder is on
  command -v systemctl >/dev/null 2>&1 || return 0
  local ud="$HOME/.config/systemd/user" u
  for u in halcyon-remind.service halcyon-remind.timer; do
    [ -f "$ud/$u" ] || { [ -f "$RICE/systemd/$u" ] && mkdir -p "$ud" && install -m644 "$RICE/systemd/$u" "$ud/$u" && systemctl --user daemon-reload >/dev/null 2>&1; }
  done
  if [ "$BACKUP_REMIND" = 1 ] || [ "$SAFETY_REMIND" = 1 ]; then systemctl --user enable --now halcyon-remind.timer >/dev/null 2>&1
  else systemctl --user disable --now halcyon-remind.timer >/dev/null 2>&1; fi
}

notify() {   # title body icon
  command -v notify-send >/dev/null 2>&1 && notify-send -a Halcyon -i "$3" "$1" "$2" 2>/dev/null
  return 0
}

json() {
  local bd sd ad al
  bd=$(last_done backup); sd=$(last_done safety); ad=$(auto_days)
  al=custom; case "$ad" in 1|7|30|90) al=$ad ;; esac
  printf '{"BACKUP_REMIND":%s,"BACKUP_EVERY":"%s","BACKUP_DAYS":%s,"SAFETY_REMIND":%s,"SAFETY_EVERY":"%s","SAFETY_DAYS":%s,"backupAgo":"%s","safetyAgo":"%s","auto":{"on":%s,"days":%s,"every":"%s"}}\n' \
    "$([ "$BACKUP_REMIND" = 1 ] && echo true || echo false)" "$BACKUP_EVERY" "$BACKUP_DAYS" \
    "$([ "$SAFETY_REMIND" = 1 ] && echo true || echo false)" "$SAFETY_EVERY" "$SAFETY_DAYS" \
    "$(ago "$bd")" "$(ago "$sd")" \
    "$(auto_on && echo true || echo false)" "$ad" "$al"
}

case "${1:-conf}" in
  conf) json ;;
  set)
    k="$2"; v="$3"
    case "$k" in
      BACKUP_REMIND|SAFETY_REMIND)
        case "$v" in 1|true|on) v=1 ;; *) v=0 ;; esac
        printf -v "$k" '%s' "$v"
        mkdir -p "$sdir"
        # turning it on starts the count: the first reminder comes one interval from now, not at once
        if [ "$v" = 1 ]; then n=$(now); case "$k" in BACKUP_REMIND) echo "$n" > "$sdir/since-backup" ;; *) echo "$n" > "$sdir/since-safety" ;; esac; fi
        write_conf; sync_timer ;;
      BACKUP_EVERY|SAFETY_EVERY)
        case "$v" in 1|7|30|90|custom) printf -v "$k" '%s' "$v"; write_conf ;; *) echo "bad $k: $v" >&2; exit 2 ;; esac ;;
      BACKUP_DAYS|SAFETY_DAYS)
        printf -v "$k" '%s' "$(clampdays "$v")"; write_conf ;;
      *) echo "unknown key: $k" >&2; exit 2 ;;
    esac ;;
  done)
    case "$2" in backup|safety) mkdir -p "$sdir"; now > "$sdir/last-$2"; rm -f "$sdir/reminded-$2" ;; *) echo "usage: remind.sh done backup|safety" >&2; exit 2 ;; esac ;;
  check)
    mkdir -p "$sdir"
    for w in backup safety; do
      case "$w" in backup) on=$BACKUP_REMIND ;; safety) on=$SAFETY_REMIND ;; esac
      [ "$on" = 1 ] || continue
      [ "$w" = safety ] && [ ! -x /usr/local/bin/safety-check ] && continue          # not installed: nothing to remind about
      d=$(days_of "$w")
      ref=$(last_done "$w"); for f in "reminded-$w" "since-$w"; do t=$(stamp "$sdir/$f"); [ "$t" -gt "$ref" ] && ref=$t; done
      [ $(( $(now) - ref )) -ge $(( d * 86400 - 3600 )) ] || continue
      ld=$(last_done "$w")
      if [ "$w" = backup ]; then
        notify "Time to back up" "Your last backup made here: $(ago "$ld"). Settings > Backup > Backup this device." drive-harddisk
      else
        notify "Time for the safety check" "Your last safety check: $(ago "$ld"). Settings > Backup > Safety check." security-medium
      fi
      now > "$sdir/reminded-$w"
    done ;;
  status)
    printf 'backup reminder : %s (every %s day(s)), last backup %s\n' "$([ "$BACKUP_REMIND" = 1 ] && echo on || echo off)" "$(days_of backup)" "$(ago "$(last_done backup)")"
    printf 'safety reminder : %s (every %s day(s)), last check %s\n' "$([ "$SAFETY_REMIND" = 1 ] && echo on || echo off)" "$(days_of safety)" "$(ago "$(last_done safety)")"
    printf 'automatic run   : %s (every %s day(s))\n' "$(auto_on && echo on || echo off)" "$(auto_days)" ;;
  *) echo "usage: remind.sh conf | set KEY VALUE | check | done backup|safety | status" >&2; exit 2 ;;
esac
