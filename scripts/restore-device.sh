#!/usr/bin/env bash
# restore-device.sh : put files back from a backup made by backup-device.sh (or the safety check).
#   Settings > System > Backup > "Restore from a backup"   (or run it by hand from a terminal)
# It only ever COPIES files back and never deletes anything: files you created after the backup stay.
# Every file it is about to overwrite is first saved in an "undo" folder, so a restore can be taken back.
# What can be restored depends on what was backed up:
#   a "home" backup   -> only your home folder (or one folder / file inside it)
#   a "system" backup -> your home folder only, OR the whole system (asks for sudo and a typed confirmation)
#   restore-device.sh            interactive: pick the disk, the backup and what to restore
#   restore-device.sh --home     only ever restore into your home folder (works with either kind of backup)
#   restore-device.sh --dry-run  show what would be copied back, copy nothing
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
HOME_ONLY=0; DRY=0
for a in "$@"; do case "$a" in --home) HOME_ONLY=1 ;; --dry-run) DRY=1 ;; -h|--help) sed -n 2,12p "$0"; exit 0 ;; esac; done
have rsync || die "rsync is not installed (sudo pacman -S rsync)"
have lsblk || die "lsblk is missing (util-linux)"

printf '%s%sRestore from a backup%s\n' "$B" "$G" "$N"
printf '%sPlug in the disk the backup is on. Nothing is deleted, and whatever gets overwritten is saved in an undo folder first.%s\n\n' "$D" "$N"

# ---- 1. the disk (external disks only, never the one this system runs from)
rootsrc=$(findmnt -no SOURCE / 2>/dev/null); rootdisk=$(lsblk -no PKNAME "${rootsrc%%[*}" 2>/dev/null | head -n1)
mapfile -t parts < <(lsblk -pP -o NAME,TYPE,RM,TRAN,PKNAME,FSTYPE,SIZE,LABEL,MOUNTPOINT 2>/dev/null | while read -r line; do
  eval "$line"
  [ "$TYPE" = part ] || [ "$TYPE" = disk ] || continue
  [ -n "$FSTYPE" ] || continue
  case "$FSTYPE" in swap|crypto_LUKS|LVM2_member|linux_raid_member) continue ;; esac
  disk=${PKNAME:-$NAME}; base=${disk#/dev/}
  [ "$base" = "$rootdisk" ] && continue
  tran=$TRAN; [ -n "$tran" ] || tran=$(lsblk -dno TRAN "$disk" 2>/dev/null)
  rm=$RM;     [ "$rm" = 1 ] || rm=$(lsblk -dno RM "$disk" 2>/dev/null)
  { [ "$tran" = usb ] || [ "$rm" = 1 ]; } || continue
  printf '%s|%s|%s|%s|%s\n' "$NAME" "$FSTYPE" "$SIZE" "${LABEL:--}" "${MOUNTPOINT:--}"
done)
[ "${#parts[@]}" -gt 0 ] || die "No external disk found. Plug it in, wait a few seconds and run this again."

echo "Connected disks:"
i=1; for p in "${parts[@]}"; do IFS='|' read -r n fs sz lb mp <<<"$p"
  printf '  %s%d)%s %s  %s  %s  label: %s  %s\n' "$B" "$i" "$N" "$n" "$sz" "$fs" "$lb" "$([ "$mp" != - ] && echo "(mounted at $mp)")"; i=$((i+1)); done
printf '\nPick the disk with your backup [1-%d, q = quit]: ' "${#parts[@]}"; read -r pick
case "$pick" in q|Q|"") exit 0 ;; esac
[[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#parts[@]}" ] || die "not a valid choice"
IFS='|' read -r dev fs size label mnt <<<"${parts[$((pick-1))]}"

if [ "$mnt" = - ]; then
  have udisksctl || die "$dev is not mounted and udisksctl (udisks2) is missing: mount it, then run this again"
  udisksctl mount -b "$dev" >/dev/null 2>&1 || die "could not mount $dev"
  mnt=$(findmnt -no TARGET "$dev" 2>/dev/null | head -n1); [ -n "$mnt" ] || die "mounted $dev but cannot find where"
fi

# ---- 2. the backups on it: Halcyon-backup/<host>/<date>/ (labelled "home" or "system"), plus the safety check's arch-backup/
meta() { sed -n "s/^$2=//p" "$1/.halcyon-backup" 2>/dev/null | head -n1; }
entries=()
if [ -d "$mnt/Halcyon-backup" ]; then
  while IFS= read -r d; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    host=$(basename "$(dirname "$d")"); stamp=$(basename "$d")
    if [ -f "$d/.halcyon-backup" ]; then scope=$(meta "$d" scope); guess=0
    else   # made before backups were labelled: a system backup has /etc and /usr in it
      if [ -d "$d/etc" ] && [ -d "$d/usr" ]; then scope=system; else scope=home; fi; guess=1
    fi
    [ "$scope" = system ] || scope=home
    entries+=("$d|$scope|$host|$stamp|$guess")
  done < <(find "$mnt/Halcyon-backup" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort -r)
fi
[ -d "$mnt/arch-backup/etc" ] && entries+=("$mnt/arch-backup|system|safety-check|latest copy|0")
[ "${#entries[@]}" -gt 0 ] || die "No Halcyon backup found on $dev (looked for Halcyon-backup/ and arch-backup/)."

echo; echo "Backups on $dev:"
i=1; for e in "${entries[@]}"; do IFS='|' read -r d scope host stamp guess <<<"$e"
  when=$(printf '%s' "$stamp" | sed -E 's/^([0-9-]+)_([0-9]+)-([0-9]+)-[0-9]+$/\1 \2:\3/')
  what=$([ "$scope" = system ] && echo "whole system" || echo "home folder only")
  printf '  %s%d)%s %s  %s   %s[%s%s]%s\n' "$B" "$i" "$N" "$host" "$when" "$G" "$what" "$([ "$guess" = 1 ] && echo ', guessed')" "$N"; i=$((i+1)); done
printf '\nPick a backup [1-%d, q = quit]: ' "${#entries[@]}"; read -r pick
case "$pick" in q|Q|"") exit 0 ;; esac
[[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#entries[@]}" ] || die "not a valid choice"
IFS='|' read -r bdir scope bhost bstamp guess <<<"${entries[$((pick-1))]}"

# ---- 3. what to restore (a home backup can only go to the home folder)
bhome=$(meta "$bdir" home); [ -n "$bhome" ] || bhome=$HOME
what=home
if [ "$scope" = system ] && [ "$HOME_ONLY" != 1 ]; then
  printf '\nThis is a whole-system backup. Restore:\n  %s1)%s my home folder only (%s)\n  %s2)%s the whole system\nChoice [1/2, q = quit]: ' "$B" "$N" "$HOME" "$B" "$N"; read -r c
  case "$c" in 1) what=home ;; 2) what=system ;; *) exit 0 ;; esac
fi

if [ "$what" = home ]; then
  if [ "$scope" = system ]; then src="$bdir$bhome"; else src="$bdir"; fi
  [ -d "$src" ] || die "this backup has no home folder inside it ($src)"
  target=$HOME
  printf '\nYou can restore everything, or just one folder or file inside your home folder.\n'
  printf 'Path inside your home (e.g. Documents or .config/Halcyon), Enter = everything: '; read -r sub
  sub=${sub#"$HOME"/}; sub=${sub#\~/}; sub=${sub#/}; sub=${sub%/}
  case "/$sub/" in */../*) die "no .. in the path" ;; esac
  [ -z "$sub" ] || [ -e "$src/$sub" ] || die "\"$sub\" is not in this backup"
else
  case "$fs" in vfat|exfat|ntfs|ntfs3|fuseblk) die "this disk is $fs, which never stored Linux owners / permissions, so a whole-system restore from it would break the system. Restore your home folder instead (option 1)." ;; esac
  have sudo || die "sudo is needed to restore the whole system (or restore the home folder only)"
  src="$bdir"; target=/; sub=""
fi

# ---- 4. what the disk's filesystem kept
flags=(-aAXH)
case "$fs" in vfat|exfat|ntfs|ntfs3|fuseblk) flags=(-rltD --modify-window=2 --no-perms --no-owner --no-group)
  printf '%s!%s %s did not keep Linux permissions or links, so files come back with default ones.\n' "$Y" "$N" "$fs" ;; esac

stamp=$(date +%Y-%m-%d_%H-%M-%S)
if [ "$what" = home ]; then undo="$HOME/.local/state/halcyon/restore-undo/$stamp"; excl=(--exclude=.cache --exclude=.local/state/halcyon/restore-undo)
else undo="/var/lib/halcyon-restore-undo/$stamp"
  excl=(--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/lost+found
        --exclude=/etc/fstab --exclude=/etc/crypttab --exclude=/var/lib/halcyon-restore-undo "--exclude=$mnt"); fi
opts=("${flags[@]}" --numeric-ids --exclude=.halcyon-backup "${excl[@]}")
[ -n "$sub" ] && { opts+=(--relative); from="$src/./$sub"; } || from="$src/"
run() { if [ "$what" = system ]; then sudo rsync "$@"; else rsync "$@"; fi; }

# ---- 5. show what would change first, then ask
printf '\n%sFrom:%s  %s  (%s backup of %s)\n%sTo:%s    %s%s\n' "$B" "$N" "$bdir" "$scope" "$bhost" "$B" "$N" "$target" "$([ -n "$sub" ] && echo "   (only $sub)")"
printf '%sLooking at what would change ...%s\n' "$D" "$N"
log=$(mktemp); run "${opts[@]}" --dry-run --itemize-changes "$from" "$target" >"$log" 2>/dev/null
n=$(grep -c '^>f' "$log"); [ -n "$n" ] || n=0
if [ "$n" = 0 ]; then printf '%sNothing to restore: everything in the backup is already here and identical.%s\n' "$G" "$N"; rm -f "$log"; exit 0; fi
printf '%s%s file(s)%s would be copied back (new or different from the backup). First ones:\n' "$B" "$n" "$N"
grep '^>f' "$log" | head -n 12 | cut -c13- | sed 's/^/    /'; [ "$n" -gt 12 ] && printf '    ... and %s more\n' "$((n-12))"; rm -f "$log"
printf '%sNothing is deleted. Files that get replaced are copied to %s first.%s\n' "$D" "$undo" "$N"

if [ "$DRY" = 1 ]; then printf '\n%sDry run finished: nothing was copied.%s\n' "$G" "$N"; exit 0; fi
if [ "$what" = system ]; then
  printf '\n%s%sThis overwrites system files (/etc, /usr, /boot ...) on the running system.%s Only do it to undo damage on this same computer.\nType RESTORE to continue: ' "$R" "$B" "$N"; read -r ok; [ "$ok" = RESTORE ] || { echo cancelled; exit 0; }
else printf '\nRestore these files now? [y/N] '; read -r ok; case "$ok" in y|Y|yes|Yes) ;; *) echo cancelled; exit 0 ;; esac; fi

# ---- 6. restore
[ "$what" = system ] && sudo mkdir -p "$undo" || mkdir -p "$undo" || die "cannot create $undo"
run "${opts[@]}" --info=progress2 --human-readable --backup "--backup-dir=$undo" "$from" "$target"; rc=$?
# 0 = ok, 24 = some files vanished while copying
if [ "$rc" = 0 ] || [ "$rc" = 24 ]; then
  sync; printf '\n%s✔ Restore finished.%s Replaced files are in %s\n' "$G" "$N" "$undo"
  [ "$what" = system ] && printf 'Restart the computer now so everything starts from the restored files.\n' || printf 'Log out and back in (or restart) so programs pick up the restored settings.\n'
  have udisksctl && { printf 'Safely eject the disk now? [Y/n] '; read -r e; case "$e" in n|N|no|No|NO) ;; *) udisksctl unmount -b "$dev" >/dev/null 2>&1 && udisksctl power-off -b "${dev%%[0-9]*}" >/dev/null 2>&1; echo "You can unplug it." ;; esac; }
else printf '\n%s✘ rsync stopped with code %s.%s Some files may be restored and some not: run it again to finish. Replaced files so far are in %s\n' "$R" "$rc" "$N" "$undo"; exit "$rc"; fi
