#!/usr/bin/env bash
# halcyon-settings-io.sh: move YOUR Halcyon settings to another machine (or back them up) as one file.
#
#   halcyon-settings-io.sh export [FILE]            write a .tar.gz (default: ~/Halcyon-settings-DATE.tar.gz)
#   halcyon-settings-io.sh import FILE [--dry-run]  put the settings back (your current ones are saved first);
#                                                   --dry-run shows each file as new / changed (with the difference) / same
#   halcyon-settings-io.sh list FILE                show what is inside
#
# What is included: the island settings (settings.json, palette, theme, gestures, default apps, display mode, focus history),
# and the files of yours that install.sh / update.sh never overwrite (hypr-user.lua, scheme/current.lua, gamemode.conf,
# special.conf, apps.custom, autostart.conf, greeting*, focus*.conf, remind.conf, notes.conf, backup-exclude.conf,
# birthdays.txt, holidays.txt).
# What is NOT included, on purpose: wallpapers and other pictures, the Google sign-in, notes, the clipboard history, and the
# per-machine files (gpu.lua, gpu-mode, the app choices in install-choices.env: another computer has another GPU / apps).
# Import only accepts files from this list, as plain files, so a handed-over archive cannot write anywhere else.
set -uo pipefail

RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/island"

STATE_FILES=(settings.json palette.json halcyon-theme.json gestures.conf apps.env display-mode.env focus-days.json)
RICE_FILES=(hypr-user.lua scheme/current.lua gamemode.conf special.conf apps.custom autostart.conf greeting.conf
            greeting-custom.txt ai-advisor.conf focus.conf focus-apps.conf remind.conf notes.conf backup-exclude.conf
            birthdays.txt holidays.txt)

die() { printf 'halcyon-settings-io: %s\n' "$*" >&2; exit 1; }
usage() { sed -n 2,10p "$0" | sed 's/^# \{0,1\}//'; }

allowed() {   # allowed NAME: is "state/x" or "rice/y" on the list?
  local n="$1" f
  case "$n" in
    MANIFEST) return 0 ;;
    state/*) for f in "${STATE_FILES[@]}"; do [ "state/$f" = "$n" ] && return 0; done ;;
    rice/*)  for f in "${RICE_FILES[@]}";  do [ "rice/$f" = "$n" ]  && return 0; done ;;
  esac
  return 1
}

do_export() {
  local out="${1:-$HOME/Halcyon-settings-$(date +%Y%m%d-%H%M%S).tar.gz}" tmp f n=0
  tmp="$(mktemp -d)" || die "cannot make a temporary folder"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/state" "$tmp/rice"
  for f in "${STATE_FILES[@]}"; do
    [ -f "$STATE/$f" ] && { mkdir -p "$tmp/state/$(dirname "$f")"; cp -p "$STATE/$f" "$tmp/state/$f" && n=$((n+1)); }
  done
  for f in "${RICE_FILES[@]}"; do
    [ -f "$RICE/$f" ] && { mkdir -p "$tmp/rice/$(dirname "$f")"; cp -p "$RICE/$f" "$tmp/rice/$f" && n=$((n+1)); }
  done
  [ "$n" -gt 0 ] || die "found nothing to export (looked in $STATE and $RICE)"
  printf 'halcyon-settings 1\ncreated %s\nhost %s\n' "$(date -Is)" "$(uname -n 2>/dev/null || echo unknown)" > "$tmp/MANIFEST"
  mkdir -p "$(dirname "$out")"
  tar -C "$tmp" -czf "$out" MANIFEST state rice || die "tar failed"
  chmod 600 "$out"   # settings can hold paths, calendar links and similar
  printf 'Exported %s files to %s\n' "$n" "$out"
}

# validate FILE: only plain files / folders, only names from the lists above, no absolute or ".." paths, and a MANIFEST.
validate() {
  local file="$1" line name bad=0 names
  [ -f "$file" ] || die "no such file: $file"
  names="$(tar -tzf "$file" 2>/dev/null)" || die "not a readable .tar.gz: $file"
  while IFS= read -r line; do
    case "${line:0:1}" in d|-) ;; *) printf 'refused (links and special files are not allowed): %s\n' "$line" >&2; bad=1 ;; esac
  done < <(tar -tvzf "$file" 2>/dev/null)
  while IFS= read -r name; do
    name="${name%/}"; name="${name#./}"; [ -n "$name" ] || continue
    case "$name" in /*|*..*) printf 'refused (unsafe path): %s\n' "$name" >&2; bad=1; continue ;; esac
    case "$name" in state|rice|rice/scheme) continue ;; esac
    allowed "$name" || { printf 'refused (not a Halcyon settings file): %s\n' "$name" >&2; bad=1; }
  done <<<"$names"
  grep -E -q '^(\./)?MANIFEST$' <<<"$names" || { echo "refused: MANIFEST missing (not a Halcyon settings export)" >&2; bad=1; }
  return "$bad"
}

do_list() { local f="${1:-}"; [ -n "$f" ] || die "list needs a file"; validate "$f" && tar -tzf "$f" | grep -v '/$'; }

# preview DIR: what an import would do, file by file, against what is on this machine now. Nothing is written.
#   new        the file does not exist here yet
#   changed    it exists and differs (the first lines of the difference follow; "-" is yours now, "+" is the import)
#   same       identical, nothing to do
preview() {
  local dir="$1" f dst kind n_new=0 n_chg=0 n_same=0 lines=40
  echo "Import preview (nothing has been changed):"
  for kind in state rice; do
    local -n list=STATE_FILES; [ "$kind" = rice ] && local -n list=RICE_FILES
    for f in "${list[@]}"; do
      [ -f "$dir/$kind/$f" ] || continue
      if [ "$kind" = state ]; then dst="$STATE/$f"; else dst="$RICE/$f"; fi
      if [ ! -e "$dst" ]; then printf '  new      %s\n' "$kind/$f"; n_new=$((n_new+1))
      elif cmp -s "$dst" "$dir/$kind/$f"; then printf '  same     %s\n' "$kind/$f"; n_same=$((n_same+1))
      else
        printf '  changed  %s\n' "$kind/$f"; n_chg=$((n_chg+1))
        diff -u --label "now/$kind/$f" --label "import/$kind/$f" "$dst" "$dir/$kind/$f" 2>/dev/null | sed -n "3,${lines}p" | sed 's/^/             /'
      fi
    done
    unset -n list
  done
  printf '%s new, %s changed, %s unchanged. Run again without --dry-run to apply (your current settings are saved first).\n' "$n_new" "$n_chg" "$n_same"
}

do_import() {
  local file="" dry=0 a tmp f n=0 stamp
  for a in "$@"; do case "$a" in --dry-run) dry=1 ;; *) file="$a" ;; esac; done
  [ -n "$file" ] || die "import needs a file"
  validate "$file" || die "refusing to import $file (see above); nothing was changed"
  tmp="$(mktemp -d)" || die "cannot make a temporary folder"
  trap 'rm -rf "$tmp"' RETURN
  tar -C "$tmp" -xzf "$file" --no-same-owner --no-same-permissions || die "extract failed"
  if [ "$dry" = 1 ]; then preview "$tmp"; return 0; fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$HOME/.cache/halcyon"
  do_export "$HOME/.cache/halcyon/settings-before-import-$stamp.tar.gz" >/dev/null 2>&1 \
    && echo "Your current settings were saved to ~/.cache/halcyon/settings-before-import-$stamp.tar.gz"
  mkdir -p "$STATE"
  for f in "${STATE_FILES[@]}"; do
    [ -f "$tmp/state/$f" ] && { mkdir -p "$STATE/$(dirname "$f")"; cp "$tmp/state/$f" "$STATE/$f" && n=$((n+1)); }
  done
  for f in "${RICE_FILES[@]}"; do
    [ -f "$tmp/rice/$f" ] && { mkdir -p "$RICE/$(dirname "$f")"; cp "$tmp/rice/$f" "$RICE/$f" && n=$((n+1)); }
  done
  printf 'Restored %s files. Log out and in again (or restart the island) to see them everywhere.\n' "$n"
}

case "${1:-}" in
  export) shift; do_export "$@" ;;
  import) shift; do_import "$@" ;;
  list)   shift; do_list "$@" ;;
  -h|--help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
