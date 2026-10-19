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
#   backup-device.sh --everything  turn the smart skip list off (normally caches, trash, game files, node_modules ... are left out)
#   backup-device.sh --verify   after copying, compare the backup with the original by checksum and report what differs
#   backup-device.sh --no-xattrs   do not copy extended attributes (rsync -X): for an rsync that errors on them; ACLs, owners, permissions are still kept
#   backup-device.sh --keep N   afterwards delete the oldest Halcyon backups on this disk, keeping the newest N (N >= 1)
#   Your own skip list: ~/.config/Halcyon/backup-exclude.conf   (a folder with a .nobackup file inside is skipped too)
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
# lsblk -P prints KEY="value" pairs. They used to be run through `eval`, so a disk whose label contains $(...) or `...` (any USB
# stick somebody hands you) ran that command as you. This reads the pairs as plain text and never runs anything.
parse_pairs() {
  local s=$1 k v
  NAME= TYPE= RM= TRAN= PKNAME= FSTYPE= SIZE= LABEL= MOUNTPOINT=
  while [[ $s =~ ^[[:space:]]*([A-Z_]+)=\"([^\"]*)\"(.*)$ ]]; do
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}; s=${BASH_REMATCH[3]}
    case "$k" in NAME|TYPE|RM|TRAN|PKNAME|FSTYPE|SIZE|LABEL|MOUNTPOINT) printf -v "$k" '%s' "$v" ;; esac
  done
  LABEL=${LABEL//|/_}; MOUNTPOINT=${MOUNTPOINT//|/_}      # "|" separates the fields below
}
HOME_ONLY=0; DRY=0; SMART=1; VERIFY=0; KEEP=0; NOX=0
while [ $# -gt 0 ]; do case "$1" in
  --home) HOME_ONLY=1 ;; --everything) SMART=0 ;; --dry-run) DRY=1 ;; --verify) VERIFY=1 ;;
  --keep) shift; KEEP="${1:-}"; [[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 1 ] || { echo "--keep needs a whole number of 1 or more" >&2; exit 2; } ;;
  --keep=*) KEEP="${1#--keep=}"; [[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 1 ] || { echo "--keep needs a whole number of 1 or more" >&2; exit 2; } ;;
  --no-xattrs) NOX=1 ;;
  -h|--help) sed -n 2,15p "$0"; exit 0 ;;
esac; shift; done
have rsync  || die "rsync is not installed (sudo pacman -S rsync)"
have lsblk  || die "lsblk is missing (util-linux)"
[ "$HOME_ONLY" = 1 ] || have sudo || die "sudo is needed to back up the whole system (or use --home)"

printf '%s%sBackup this device%s\n' "$B" "$G" "$N"
printf '%sPlug in the hard disk / SSD / USB drive. Nothing on it is erased.%s\n\n' "$D" "$N"

# the disk that holds / : never offer it as the target
rootsrc=$(findmnt -no SOURCE / 2>/dev/null); rootdisk=$(lsblk -no PKNAME "${rootsrc%%[*}" 2>/dev/null | head -n1)

# external disks only: removable or on USB, and not the system disk
mapfile -t parts < <(lsblk -pP -o NAME,TYPE,RM,TRAN,PKNAME,FSTYPE,SIZE,LABEL,MOUNTPOINT 2>/dev/null | while read -r line; do
  parse_pairs "$line"
  [ "$TYPE" = part ] || [ "$TYPE" = disk ] || continue
  [ -n "$FSTYPE" ] || continue
  case "$FSTYPE" in swap|crypto_LUKS|LVM2_member|linux_raid_member) continue ;; esac
  disk=${PKNAME:-$NAME}; base=${disk#/dev/}
  [ "$base" = "$rootdisk" ] && continue
  tran=$TRAN; [ -n "$tran" ] || tran=$(lsblk -dno TRAN "$disk" 2>/dev/null)
  isrm=$RM;   [ "$isrm" = 1 ] || isrm=$(lsblk -dno RM "$disk" 2>/dev/null)
  { [ "$tran" = usb ] || [ "$isrm" = 1 ]; } || continue
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
[ "$NOX" = 1 ] && flags=("${flags[@]//X/}")        # -aAXH -> -aAH

host=$(hostname 2>/dev/null || echo pc); stamp=$(date +%Y-%m-%d_%H-%M-%S)
root="$mnt/Halcyon-backup/$host"; dest="$root/$stamp"
src=/; excl=(--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/mnt --exclude=/media
  --exclude=/lost+found --exclude=/var/tmp --exclude=/var/cache --exclude=/var/lib/pacman/sync --exclude=/var/lib/apt/lists "--exclude=$mnt" --exclude=/swapfile --exclude=/.snapshots)
if [ "$HOME_ONLY" = 1 ]; then src="$HOME/"; excl=(--exclude=.cache --exclude=.local/share/Trash --exclude=.local/share/gvfs-metadata --exclude="*.sock" "--exclude=$mnt"); fi

# ---- smart skip list: things that rebuild themselves (caches, trash, package downloads, game files, node_modules ...).
#      They are not backed up, so the backup is smaller and faster. --everything turns this off.
smart_rel=( .cache .thumbnails .local/share/Trash .local/share/gvfs-metadata .local/share/baloo .local/state/halcyon/restore-undo
  .npm .yarn/cache .local/share/pnpm .cargo/registry .cargo/git .gradle/caches .m2/repository .ccache go/pkg/mod
  .local/share/containers/storage '.var/app/*/cache' '.var/app/*/.cache'
  .local/share/Steam/steamapps/common .local/share/Steam/steamapps/shadercache .local/share/Steam/steamapps/downloading .local/share/Steam/steamapps/temp
  '.var/app/*/.local/share/Steam/steamapps/common'
  '.config/*/Cache' '.config/*/Code Cache' '.config/*/GPUCache' '.config/*/GrShaderCache' '.config/*/ShaderCache'
  '.config/*/*/Cache' '.config/*/*/Code Cache' '.config/*/*/GPUCache' '.config/*/*/Service Worker/CacheStorage' )
smart_any=( node_modules __pycache__ )
conf="$HOME/.config/Halcyon/backup-exclude.conf"      # your own additions: one rsync pattern per line
if [ "$SMART" = 1 ]; then
  # (rsync has no --exclude-if-present: folders holding CACHEDIR.TAG or .nobackup are found below and passed as --exclude-from)
  if [ "$HOME_ONLY" = 1 ]; then
    for r in "${smart_rel[@]}"; do excl+=("--exclude=/$r"); done
    for a in "${smart_any[@]}"; do excl+=("--exclude=$a"); done
  else
    for r in "${smart_rel[@]}"; do excl+=("--exclude=/home/*/$r" "--exclude=/root/$r"); done
    for a in "${smart_any[@]}"; do excl+=("--exclude=/home/*/$a" "--exclude=/home/*/**/$a"); done
    excl+=(--exclude=/var/lib/systemd/coredump)
  fi
  if [ ! -e "$conf" ] && mkdir -p "$(dirname "$conf")" 2>/dev/null; then
    cat > "$conf" 2>/dev/null <<'CONF_EOF'
# Extra things to leave out of backups (backup-device.sh). One rsync pattern per line, # = comment.
# Home backup: paths are relative to your home folder, e.g.    Videos/raw      or      *.iso
# Whole system backup: write the full path, e.g.               /home/you/Videos/raw
# To skip a whole folder without editing this file, put an empty file called .nobackup inside it.
CONF_EOF
  fi
  if [ -f "$conf" ]; then
    while IFS= read -r l; do
      l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case "$l" in ""|"#"*) continue ;; esac
      excl+=("--exclude=$l")
    done < "$conf"
  fi
fi

printf '\n%sFrom:%s  %s\n%sTo:%s    %s   (%s, %s free)\n' "$B" "$N" "$([ "$HOME_ONLY" = 1 ] && echo "your home folder" || echo "the whole system")" "$B" "$N" "$dest" "$fs" "$(df -h --output=avail "$mnt" | tail -n1 | tr -d ' ')"
if [ "$HOME_ONLY" != 1 ]; then
  need=$(df -B1 --output=used / | tail -n1 | tr -d ' '); have_b=$(df -B1 --output=avail "$mnt" | tail -n1 | tr -d ' ')
  [ "$have_b" -gt "$need" ] 2>/dev/null || printf '%s!%s The disk looks smaller than the used space on this computer (%s used): it may fill up.\n' "$Y" "$N" "$(df -h --output=used / | tail -n1 | tr -d ' ')"
fi
if [ "$SMART" = 1 ]; then
  big=""
  for r in "${smart_rel[@]}"; do
    case "$r" in *\**) continue ;; esac
    [ -e "$HOME/$r" ] || continue
    k=$(timeout 6 du -sk "$HOME/$r" 2>/dev/null | cut -f1)
    [ "${k:-0}" -ge 51200 ] 2>/dev/null && big+=$(printf '\n    %-46s %s MB' "~/$r" "$((k / 1024))")
  done
  printf '%sLeft out on purpose%s (they rebuild by themselves): caches, trash, package downloads, game files, node_modules ...\n' "$B" "$N"
  [ -n "$big" ] && printf '  The big ones on this computer:%s\n' "$big"
  printf '  %sAdd your own in %s, or run with --everything to turn the skip list off.%s\n' "$D" "$conf" "$N"
fi
[ "$DRY" = 1 ] || { printf 'Start the backup? [Y/n] '; read -r ok; case "$ok" in n|N|no|No|NO) echo cancelled; exit 0 ;; esac; }

# Folders that carry a CACHEDIR.TAG (the standard "this is only a cache" marker) or an empty .nobackup file are left out whole.
# rsync cannot do that by itself, so look for the markers first and give rsync the folders as exact, anchored excludes.
exfile=""
if [ "$SMART" = 1 ]; then
  exfile=$(mktemp 2>/dev/null) || exfile=""
  if [ -n "$exfile" ]; then
    trap 'rm -f "$exfile"' EXIT
    if [ "$HOME_ONLY" = 1 ]; then scan=("$HOME"); strip="$HOME"; else scan=(/home /root); strip=""; fi
    printf '%sLooking for folders marked CACHEDIR.TAG / .nobackup ...%s\n' "$D" "$N"
    while IFS= read -r -d '' f; do
      d=${f%/*}
      case "${f##*/}" in
        CACHEDIR.TAG) head -c 43 "$f" 2>/dev/null | grep -q '^Signature: 8a477f597d28d172789f06886806bc55' || continue ;;
      esac
      [ -n "$strip" ] && d=${d#"$strip"}
      [ -n "$d" ] || continue                                   # never exclude the whole transfer root
      d=$(printf '%s' "$d" | sed 's/[][*?\\]/\\&/g')            # a folder name with * ? [ ] or \ must match literally
      printf '%s/\n' "$d" >> "$exfile"
    done < <(timeout 120 find "${scan[@]}" -xdev \( -name node_modules -o -name .cache -o -path "*/steamapps/common" \) -prune -o \
               \( -name CACHEDIR.TAG -o -name .nobackup \) -type f -print0 2>/dev/null)
    [ -s "$exfile" ] && excl+=("--exclude-from=$exfile")
  fi
fi

build_opts() {
  opts=("${flags[@]}" --info=progress2 --human-readable --numeric-ids "${excl[@]}")
  [ "$link" = 1 ] && [ -e "$root/latest" ] && opts+=("--link-dest=$(readlink -f "$root/latest")")
  [ "$DRY" = 1 ] && opts+=(--dry-run)
  return 0
}
# rsync's own error lines go to a log file instead of flooding the screen (the progress still shows); a summary is printed afterwards.
rlog="${XDG_STATE_HOME:-$HOME/.local/state}/halcyon/backup-last.log"; mkdir -p "$(dirname "$rlog")" 2>/dev/null; : > "$rlog" 2>/dev/null || rlog=/dev/null
run_rsync() {
  : > "$rlog" 2>/dev/null
  if [ "$HOME_ONLY" = 1 ]; then rsync "${opts[@]}" "$src" "$dest/" 2>>"$rlog"; else sudo rsync "${opts[@]}" "$src" "$dest/" 2>>"$rlog"; fi
}
build_opts
mkdir -p "$dest" || die "cannot create $dest"
if printf '%s\n' "${opts[@]}" | grep -q '^--link-dest='; then printf '%sComparing with the previous backup (unchanged files are hard-linked): %s%s\n' "$D" "$(readlink -f "$root/latest")" "$N"
else printf '%sNo earlier backup on this disk: this is a full copy.%s\n' "$D" "$N"; fi
run_rsync; rc=$?

# Some rsync builds fail on extended attributes (-X) with "gen_entry_copy_xattrs ... secure open ... failed". Offer to go on without them.
if [ "$rc" != 0 ] && [ "$rc" != 24 ] && [ "$NOX" = 0 ] && grep -qiE 'xattr' "$rlog" 2>/dev/null; then
  printf '\n%s!%s rsync %s failed while handling extended attributes (-X). First lines:\n' "$Y" "$N" "$(rsync --version 2>/dev/null | head -n1 | awk '{print $3}')"
  head -n 3 "$rlog" | cut -c1-200 | sed 's/^/    /'
  printf 'Try again without extended attributes? ACLs, owners and permissions are still kept; file capabilities (e.g. ping) and SELinux labels are not. [Y/n] '
  read -r ans
  case "$ans" in n|N|no|No|NO) ;; *) NOX=1; flags=("${flags[@]//X/}"); build_opts; run_rsync; rc=$? ;; esac
fi
if [ -s "$rlog" ]; then
  n=$(wc -l < "$rlog"); printf '\n%srsync printed %s message(s); the first ones:%s\n' "$Y" "$n" "$N"; head -n 5 "$rlog" | cut -c1-220 | sed 's/^/    /'; printf '    full list: %s\n' "$rlog"
fi

# 0 = ok, 24 = some files vanished while copying (normal on a running system)
if [ "$rc" = 0 ] || [ "$rc" = 24 ]; then
  if [ "$DRY" = 1 ]; then rmdir "$dest" 2>/dev/null; printf '\n%sDry run finished: nothing was copied.%s\n' "$G" "$N"
  else
    printf 'scope=%s\nuser=%s\nhome=%s\nhost=%s\ndate=%s\nfs=%s\n' "$([ "$HOME_ONLY" = 1 ] && echo home || echo system)" "$(id -un)" "$HOME" "$host" "$stamp" "$fs" > "$dest/.halcyon-backup"
    ln -sfn "$stamp" "$root/latest"; sync; printf '\n%s✔ Backup finished:%s %s\n' "$G" "$N" "$dest"
    # ---- --verify: compare by checksum, same skip list. A running system changes while it is copied, so a few differences are normal.
    if [ "$VERIFY" = 1 ]; then
      printf '%sVerifying (reads every file again, this takes a while) ...%s\n' "$D" "$N"
      vopts=(-rn --checksum --itemize-changes "${excl[@]}")
      if [ "$HOME_ONLY" = 1 ]; then vout=$(rsync "${vopts[@]}" "$src" "$dest/" 2>&1); else vout=$(sudo rsync "${vopts[@]}" "$src" "$dest/" 2>&1); fi
      vdiff=$(printf '%s\n' "$vout" | grep -cE '^[<>c][fdLDS]')
      if [ "$vdiff" = 0 ]; then printf '%s✔ Verified:%s every copied file matches the original.\n' "$G" "$N"
      else printf '%s!%s %s file(s) differ from the original (normal for files that changed during the backup). First ones:\n' "$Y" "$N" "$vdiff"
           printf '%s\n' "$vout" | grep -E '^[<>c][fdLDS]' | head -n 10 | sed 's/^/    /'; fi
    fi
    # ---- --keep N: delete the oldest Halcyon backups. Only dated folders that hold our .halcyon-backup marker are ever touched.
    if [ "$KEEP" -ge 1 ]; then
      mapfile -t all < <(find "$root" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' -printf '%f\n' 2>/dev/null | sort)
      drop=$(( ${#all[@]} - KEEP )); removed=0
      if [ "$drop" -gt 0 ]; then
        for old in "${all[@]:0:drop}"; do
          [ "$old" != "$stamp" ] && [ -f "$root/$old/.halcyon-backup" ] || continue       # never the new one, never a folder that is not ours
          printf '  removing old backup %s\n' "$old"
          if grep -q '^scope=system' "$root/$old/.halcyon-backup" 2>/dev/null; then sudo rm -rf --one-file-system -- "${root:?}/$old"; else rm -rf --one-file-system -- "${root:?}/$old"; fi
          removed=$((removed+1))
        done
      fi
      printf '%s✔%s kept the newest %s backup(s)%s\n' "$G" "$N" "$KEEP" "$([ "$removed" -gt 0 ] && echo ", removed $removed older one(s)")"
    fi
    bash "${HALCYON_DIR:-$HOME/.config/Halcyon}/scripts/remind.sh" done backup 2>/dev/null   # for Settings > Backup > Remind me
    have udisksctl && { printf 'Safely eject the disk now? [Y/n] '; read -r e; case "$e" in n|N|no|No|NO) ;; *) udisksctl unmount -b "$dev" >/dev/null 2>&1 && udisksctl power-off -b "${dev%%[0-9]*}" >/dev/null 2>&1; echo "You can unplug it." ;; esac; }
  fi
else
  rmdir "$dest" 2>/dev/null          # nothing was copied: do not leave an empty dated folder on the disk
  if [ -d "$dest" ]; then printf '\n%s✘ rsync stopped with code %s.%s The partly copied folder is %s (not marked as "latest"). Running again starts a new dated folder; delete this one when you no longer need it.\n' "$R" "$rc" "$N" "$dest"
  else printf '\n%s✘ rsync stopped with code %s before copying anything.%s Nothing was left on the disk.\n' "$R" "$rc" "$N"; fi
  exit "$rc"
fi
