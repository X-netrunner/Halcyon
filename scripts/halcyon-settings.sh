#!/usr/bin/env bash
# halcyon-settings.sh: save your Halcyon setup in one file, and put it back (after a reinstall, or on a second computer).
#   halcyon-settings.sh export [file.tar.gz]   default: ~/halcyon-settings-<date>.tar.gz
#   halcyon-settings.sh import file.tar.gz     puts the files back; whatever they replace is first saved as <name>.before-import
#   halcyon-settings.sh list file.tar.gz       show what is inside, change nothing
# Only a fixed list of small files is ever packed or unpacked (nothing from outside it, no matter what the archive says):
#   the island settings, your hypr-user.lua, the colour scheme, the gaming-mode config and your backup skip list.
# It does not pack passwords, tokens, notes, wallpapers or browser data.
set -uo pipefail
tmp=""
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/island"
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
die() { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# archive name -> where it lives on this computer
declare -A WHERE=(
  [island/settings.json]="$STATE/settings.json"
  [Halcyon/hypr-user.lua]="$RICE/hypr-user.lua"
  [Halcyon/scheme/current.lua]="$RICE/scheme/current.lua"
  [Halcyon/gamemode.conf]="$RICE/gamemode.conf"
  [Halcyon/backup-exclude.conf]="$RICE/backup-exclude.conf"
)
ORDER=(island/settings.json Halcyon/hypr-user.lua Halcyon/scheme/current.lua Halcyon/gamemode.conf Halcyon/backup-exclude.conf)

cmd_export() {
  local out="${1:-$HOME/halcyon-settings-$(date +%Y-%m-%d).tar.gz}" name n=0 have=()
  tmp=$(mktemp -d) || die "no temp folder"; trap 'rm -rf "${tmp:-}"' EXIT
  for name in "${ORDER[@]}"; do
    [ -f "${WHERE[$name]}" ] || continue
    mkdir -p "$tmp/$(dirname "$name")"; cp -- "${WHERE[$name]}" "$tmp/$name" && { printf '  + %s\n' "$name"; have+=("$name"); n=$((n+1)); }
  done
  [ "$n" -gt 0 ] || die "nothing to save yet (no settings found under $RICE or $STATE)"
  (cd "$tmp" && tar -czf "$out" "${have[@]}") || die "could not write $out"
  printf '%s✔%s saved %s file(s) to %s\n' "$G" "$N" "$n" "$out"
}

# the archive may only hold the listed regular files: no absolute paths, no "..", no links, nothing else
check_archive() {
  local f="$1" line name
  [ -f "$f" ] || die "$f is not a file"
  tar -tzf "$f" >/dev/null 2>&1 || die "$f is not a readable .tar.gz"
  while IFS= read -r line; do
    name=${line#./}
    case "$line" in */) continue ;; esac
    [ -n "${WHERE[$name]+x}" ] || die "the archive holds '$line', which is not one of the files this tool restores: refusing"
  done < <(tar -tzf "$f")
  tar -tvzf "$f" | awk '{ t = substr($1,1,1); if (t != "-" && t != "d") bad = 1 } END { exit bad }' || die "the archive holds links or special files: refusing"
  return 0
}

cmd_list() { check_archive "$1"; tar -tzf "$1" | grep -v '/$'; }

cmd_import() {
  local f="${1:-}" name dest
  [ -n "$f" ] || die "usage: halcyon-settings.sh import file.tar.gz"
  check_archive "$f"
  tmp=$(mktemp -d) || die "no temp folder"; trap 'rm -rf "${tmp:-}"' EXIT
  tar -xzf "$f" -C "$tmp" --no-same-owner --no-same-permissions || die "could not unpack $f"
  for name in "${ORDER[@]}"; do
    [ -f "$tmp/$name" ] || continue
    dest="${WHERE[$name]}"
    case "$name" in island/settings.json)
        if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/$name" 2>/dev/null \
          || { printf '%s!%s %s is not valid JSON: skipped\n' "$Y" "$N" "$name"; continue; }; fi ;; esac
    mkdir -p "$(dirname "$dest")"
    [ -e "$dest" ] && cp -p -- "$dest" "$dest.before-import"
    cp -- "$tmp/$name" "$dest" && printf '  %s✔%s %s -> %s\n' "$G" "$N" "$name" "$dest"
  done
  echo "Reload to see it:  quickshell ipc -p $RICE/quickshell/island call island reload   (or log out and in)"
}

case "${1:-}" in
  export) shift; cmd_export "${1:-}" ;;
  import) shift; cmd_import "${1:-}" ;;
  list)   shift; cmd_list "${1:-}" ;;
  *) sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'; [ "${1:-}" = -h ] || [ "${1:-}" = --help ] || exit 2 ;;
esac
