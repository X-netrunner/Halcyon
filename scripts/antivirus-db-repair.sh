#!/usr/bin/env bash
# antivirus-db-repair.sh: make the alert history readable again when ai-antivirus was downgraded.
#
# Symptom this fixes (Security center > Antivirus, "Unlock failed"):
#   database schema version 4 is newer than the supported version 3
# A newer engine upgraded the database in place. An older engine can not read it and keeps refusing every alert, even as
# root. The data is not lost: this script copies the database, moves it aside and lets the engine create a fresh one at the
# schema the installed binary understands, then puts the old ownership back.
#
#   sudo bash antivirus-db-repair.sh          # what the Security center runs
#   sudo bash antivirus-db-repair.sh --dry-run   # only says what it would do
#
# Nothing else is touched: rules, config, the event log, quarantine and exceptions stay as they are. The archived database
# stays next to the new one (and in backups/), so it can be inspected or restored by a newer ai-antivirus.
set -uo pipefail

STATE=/var/lib/ai-antivirus
DB="$STATE/ai-antivirus.db"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "this needs root (run it with sudo)"
[ -f "$DB" ] || { say "There is no alert database yet, so there is nothing to repair."; exit 0; }

# who owns the state folder: the engine runs as its own user, so the fresh files must be that user's too
OWNER=$(stat -c '%u:%g' "$STATE" 2>/dev/null || echo "")
[ -n "$OWNER" ] || die "can not read $STATE"

STAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$STATE/backups/ai-antivirus.db.unreadable-$STAMP"
mkdir -p "$STATE/backups" || die "can not create $STATE/backups"

if [ "$DRY" = 1 ]; then
    say "would stop the engine, copy $DB to $ARCHIVE, create a fresh database as $OWNER and start the engine again"
    exit 0
fi

start_services() {
    for u in ai-antivirus-sensord ai-antivirus-engined ai-antivirus-responderd; do
        systemctl start "$u" >/dev/null 2>&1 || true
    done
}
# stop the services that hold the database open (a short pause; the sensor starts again at the end)
for u in ai-antivirus-responderd ai-antivirus-engined ai-antivirus-sensord; do
    systemctl stop "$u" >/dev/null 2>&1 || true
done

# keep the exact file first, then move it out of the way so db-init writes a new one.
# -wal / -shm are part of the database while SQLite is in WAL mode: they are copied and moved with it (a stale sidecar
# next to a fresh database would make the new one unreadable).
cp -a "$DB" "$ARCHIVE" || { say "could not copy the database; nothing was changed." >&2; start_services; exit 1; }
for ext in -wal -shm; do [ -f "$DB$ext" ] && cp -a "$DB$ext" "$ARCHIVE$ext"; done
if ! mv -f "$DB" "$ARCHIVE.original"; then
    say "could not move the database aside; nothing was changed." >&2
    start_services
    exit 1
fi
for ext in -wal -shm; do [ -f "$DB$ext" ] && mv -f "$DB$ext" "$ARCHIVE.original$ext"; done
rm -f "$DB-wal" "$DB-shm"          # nothing of the old database may sit next to the new one

# create the schema the installed engine understands
if ! ai-antivirus db-init >/dev/null 2>&1; then
    # put the old one back: a failed repair must not leave the system without a database
    rm -f "$DB" "$DB-wal" "$DB-shm"
    mv -f "$ARCHIVE.original" "$DB"
    for ext in -wal -shm; do [ -f "$ARCHIVE.original$ext" ] && mv -f "$ARCHIVE.original$ext" "$DB$ext"; done
    chown "$OWNER" "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true
    start_services
    printf 'error: the installed ai-antivirus could not create a database either. Run: ai-antivirus db-stats\n' >&2
    exit 1
fi

# the engine runs as its own user; a root-owned database would lock it out just as badly
chown "$OWNER" "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true
chmod 600 "$DB" 2>/dev/null || true

start_services
sleep 0.4
if ai-antivirus db-stats >/dev/null 2>&1; then
    say "Repaired. The old history is kept at $ARCHIVE."
else
    say "The database was recreated, but the engine still can not read it. Run: ai-antivirus db-stats"
fi
