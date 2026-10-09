#!/usr/bin/env bash
# backup-device.sh : back up this whole computer onto an external disk you plug in.
#   Settings > System > Backup > "Backup this device"   (or run it by hand from a terminal)
# It never formats or erases the disk. Each run makes a new dated folder on the disk:
#   <disk>/Halcyon-backup/<hostname>/<date-time>/      (unchanged files are hard-linked to the previous run, so it stays small)
#   <disk>/Halcyon-backup/<hostname>/latest            (link to the newest run)
# Restore = copy the files back (rsync -aAXH <disk>/Halcyon-backup/<host>/latest/ /).
#   backup-device.sh            interactive: pick the disk, confirm, back up
#   backup-device.sh --home     only your home folder (no root needed)
#   backup-device.sh --dry-run  show what would be copied, copy nothing
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
HOME_ONLY=0; DRY=0
for a in "$@"; do case "$a" in --home) HOME_ONLY=1 ;; --dry-run) DRY=1 ;; -h|--help) sed -n 2,11p "$0"; exit 0 ;; esac; done
have rsync  || die "rsync is not installed (sudo pacman -S rsync)"
have lsblk  || die "lsblk is missing (util-linux)"
[ "$HOME_ONLY" = 1 ] || have sudo || die "sudo is needed to back up the whole system (or use --home)"

printf '%s%sBackup this device%s\n' "$B" "$G" "$N"
printf '%sPlug in the hard disk / SSD / USB drive. Nothing on it is erased.%s\n\n' "$D" "$N"

# the disk that holds / : never offer it as the target
rootsrc=$(findmnt -no SOURCE / 2>/dev/null); rootdisk=$(lsblk -no PKNAME "${rootsrc%%[*}" 2>/dev/null | head -n1)

# external disks only: removable or on USB, and not the system disk
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
printf '\nPick a disk [1-%d, q = quit]: ' "${#parts[@]}"; read -r pick
case "$pick" in q|Q|"") exit 0 ;; esac
[[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#parts[@]}" ] || die "not a valid choice"
IFS='|' read -r dev fs size label mnt <<<"${parts[$((pick-1))]}"

# mount it if it is not mounted yet (udisksctl needs no root)
if [ "$mnt" = - ]; then
  have udisksctl || die "$dev is not mounted and udisksctl (udisks2) is missing: mount it, then run this again"
  udisksctl mount -b "$dev" >/dev/null 2>&1 || die "could not mount $dev"
  mnt=$(findmnt -no TARGET "$dev" 2>/dev/null | head -n1); [ -n "$mnt" ] || die "mounted $dev but cannot find where"
fi
[ -w "$mnt" ] || die "$mnt is read-only for you (a read-only disk, or a filesystem such as NTFS that was not unmounted cleanly)"

# what the disk's filesystem can keep
flags=(-aAXH); link=1
case "$fs" in
  vfat|exfat|ntfs|ntfs3|fuseblk) flags=(-rltD --modify-window=2 --no-perms --no-owner --no-group); link=0
    printf '%s!%s %s cannot store Linux permissions or links: files are copied, but owners / permissions are not kept.\n  For a full system backup format the disk as ext4 or btrfs yourself first.\n' "$Y" "$N" "$fs" ;;
esac

host=$(hostname 2>/dev/null || echo pc); stamp=$(date +%Y-%m-%d_%H-%M-%S)
root="$mnt/Halcyon-backup/$host"; dest="$root/$stamp"
src=/; excl=(--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/mnt --exclude=/media
  --exclude=/lost+found --exclude=/var/tmp --exclude=/var/cache --exclude=/var/lib/pacman/sync "--exclude=$mnt" --exclude=/swapfile --exclude=/.snapshots)
if [ "$HOME_ONLY" = 1 ]; then src="$HOME/"; excl=(--exclude=.cache --exclude=.local/share/Trash "--exclude=$mnt"); fi

printf '\n%sFrom:%s  %s\n%sTo:%s    %s   (%s, %s free)\n' "$B" "$N" "$([ "$HOME_ONLY" = 1 ] && echo "your home folder" || echo "the whole system")" "$B" "$N" "$dest" "$fs" "$(df -h --output=avail "$mnt" | tail -n1 | tr -d ' ')"
if [ "$HOME_ONLY" != 1 ]; then
  need=$(df -B1 --output=used / | tail -n1 | tr -d ' '); have_b=$(df -B1 --output=avail "$mnt" | tail -n1 | tr -d ' ')
  [ "$have_b" -gt "$need" ] 2>/dev/null || printf '%s!%s The disk looks smaller than the used space on this computer (%s used): it may fill up.\n' "$Y" "$N" "$(df -h --output=used / | tail -n1 | tr -d ' ')"
fi
[ "$DRY" = 1 ] || { printf 'Start the backup? [y/N] '; read -r ok; case "$ok" in y|Y|yes) ;; *) echo cancelled; exit 0 ;; esac; }

opts=("${flags[@]}" --info=progress2 --human-readable --numeric-ids "${excl[@]}")
[ "$link" = 1 ] && [ -e "$root/latest" ] && opts+=("--link-dest=$(readlink -f "$root/latest")")
[ "$DRY" = 1 ] && opts+=(--dry-run)
mkdir -p "$dest" || die "cannot create $dest"
if [ "$HOME_ONLY" = 1 ]; then rsync "${opts[@]}" "$src" "$dest/"; rc=$?
else sudo rsync "${opts[@]}" "$src" "$dest/"; rc=$?; fi

# 0 = ok, 24 = some files vanished while copying (normal on a running system)
if [ "$rc" = 0 ] || [ "$rc" = 24 ]; then
  if [ "$DRY" = 1 ]; then rmdir "$dest" 2>/dev/null; printf '\n%sDry run finished: nothing was copied.%s\n' "$G" "$N"
  else ln -sfn "$stamp" "$root/latest"; sync; printf '\n%s✔ Backup finished:%s %s\n' "$G" "$N" "$dest"
    have udisksctl && { printf 'Safely eject the disk now? [y/N] '; read -r e; case "$e" in y|Y) udisksctl unmount -b "$dev" >/dev/null 2>&1 && udisksctl power-off -b "${dev%%[0-9]*}" >/dev/null 2>&1; echo "You can unplug it." ;; esac; }
  fi
else printf '\n%s✘ rsync stopped with code %s.%s The unfinished copy is in %s : run again to continue (it is not marked as "latest").\n' "$R" "$rc" "$N" "$dest"; exit "$rc"; fi
