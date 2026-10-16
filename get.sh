#!/usr/bin/env bash
# Halcyon, one line: downloads Halcyon from GitHub and runs its installer. Nothing else is needed first except git.
#
#   curl -fsSL https://raw.githubusercontent.com/X-netrunner/Halcyon/HEAD/get.sh | bash
#
# Options go after  -s --  (they are handed to install.sh, or to update.sh when Halcyon is already there):
#
#   curl -fsSL https://raw.githubusercontent.com/X-netrunner/Halcyon/HEAD/get.sh | bash -s -- --yes --no-sysmode
#
#   --yes / -y         no questions (the saved answers, or the defaults, are used)
#   --dry-run          download to a cache folder and only SHOW what install.sh would do; nothing is installed
#   --help             this text
#   anything else      goes on to install.sh unchanged (--browser zen, --files yazi,thunar, --no-packages, --resources low ...,
#                      see ./install.sh --help)
#
# What it does
#   no Halcyon yet                 git clone into ~/.config/Halcyon, then ./install.sh there. Because it is a git checkout,
#                                  ~/.config/Halcyon/update.sh later updates it in place and keeps your own edits.
#   ~/.config/Halcyon is a git checkout    nothing is downloaded here: update.sh does the update (same options).
#   ~/.config/Halcyon is a plain copy      the newest version is cloned to ~/.cache/halcyon-get and installed over it
#                                  (install.sh saves the old copy in ~/.config/Halcyon-backups and keeps hypr-user.lua,
#                                  scheme/current.lua and the other files of yours).
#
# Environment: HALCYON_REPO (another repository / fork)   HALCYON_DIR (another folder than ~/.config/Halcyon)
#
# You are piping a script into bash: read it first if you like (curl -fsSL <the url above> | less). It only runs git and
# install.sh from the repository above, never as root, and asks for sudo only where install.sh needs it.
#
# The whole script is inside main(), and the last line is "main; exit": bash has read all of it before it runs anything, so
# a half-downloaded script never runs half of itself, and install.sh can read your answers from the terminal while the
# script itself is still coming through the pipe.
set -uo pipefail

main() {
  local REPO_URL="${HALCYON_REPO:-https://github.com/X-netrunner/Halcyon}"
  local RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
  local STATE="$HOME/.local/state/halcyon"
  local CACHE="$HOME/.cache/halcyon-get"
  local C_H= C_OK= C_W= C_E= C_0=
  if [ -t 1 ]; then C_H=$'\033[1;36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'; C_0=$'\033[0m'; fi
  say()  { printf '%s== %s%s\n' "$C_H" "$*" "$C_0"; }
  ok()   { printf '   %s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
  warn() { printf '   %s!%s %s\n' "$C_W" "$C_0" "$*"; }
  die()  { printf '   %s✗%s %s\n' "$C_E" "$C_0" "$*" >&2; exit 1; }

  local ARGS=() DRY=0 YES=0 a
  for a in "$@"; do
    case "$a" in
      -h|--help) sed -n '2,/^# Environment:/p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'
                 [ -r "${BASH_SOURCE[0]:-}" ] || echo "Halcyon one-line installer: curl -fsSL <url>/get.sh | bash -s -- [install.sh options]"
                 return 0 ;;
      --dry-run) DRY=1; ARGS+=("$a") ;;
      -y|--yes)  YES=1; ARGS+=("$a") ;;
      *)         ARGS+=("$a") ;;
    esac
  done

  [ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root (it asks for sudo itself where needed)."
  [ "$(uname -s)" = "Linux" ] || die "Halcyon is for Linux (Arch and Arch-based systems)."
  command -v timeout >/dev/null || die "timeout (coreutils) is required."

  # a terminal for the questions: when this script comes through a pipe, stdin is the pipe, so the children get the tty
  local TTY=0
  if [ -t 0 ]; then TTY=1
  elif { : </dev/tty; } 2>/dev/null; then TTY=2; fi
  if [ "$TTY" = 0 ] && [ "$YES" = 0 ]; then
    warn "no terminal to ask questions on: running with --yes (saved answers, or the defaults)"
    ARGS+=(--yes); YES=1
  fi
  # run <cmd...> with the terminal as stdin when we were piped
  withtty() { if [ "$TTY" = 2 ]; then "$@" </dev/tty; else "$@"; fi; }

  if ! command -v git >/dev/null; then
    if command -v pacman >/dev/null && [ "$TTY" != 0 ] && [ "$YES" = 0 ]; then
      local r; read -r -p "   git is missing. Install it now (sudo pacman -S --needed git)? [Y/n] " r </dev/tty
      [[ "$r" =~ ^[nN] ]] && die "git is required."
      sudo pacman -S --needed git || die "could not install git."
    elif command -v pacman >/dev/null && [ "$YES" = 1 ]; then
      sudo pacman -S --needed --noconfirm git || die "could not install git."
    else
      die "git is required (sudo pacman -S git / sudo apt install git)."
    fi
  fi
  command -v bash >/dev/null || die "bash is required."

  mkdir -p "$STATE" "$HOME/.cache" || die "cannot create $STATE"
  export GIT_TERMINAL_PROMPT=0

  # ---- Halcyon is already there as a git checkout: that is update.sh's job
  if [ "$DRY" = 0 ] && [ -d "$RICE/.git" ] && [ -f "$RICE/update.sh" ]; then
    say "Halcyon is already in $RICE: updating it"
    withtty bash "$RICE/update.sh" ${ARGS[@]+"${ARGS[@]}"}
    return $?
  fi

  say "Checking $REPO_URL"
  timeout 30 git ls-remote --exit-code "$REPO_URL" HEAD >/dev/null 2>&1 || die "cannot reach $REPO_URL (offline? wrong HALCYON_REPO?)"

  # ---- where the download goes
  #   fresh install: straight to the final folder (a git checkout, so update.sh works in place)
  #   plain copy there, or --dry-run: a cache folder, install.sh does the copying (and the backup)
  local SRC kind
  if [ "$DRY" = 0 ] && { [ ! -e "$RICE" ] || [ -z "$(ls -A "$RICE" 2>/dev/null)" ]; } && [ ! -L "$RICE" ]; then
    SRC="$RICE"; kind=fresh
  else
    SRC="$CACHE"; kind=cache
    if [ "$DRY" = 0 ]; then warn "$RICE already exists and is not a git checkout: the newest version is installed over it (your old copy is saved in ~/.config/Halcyon-backups)"; fi
  fi

  say "Downloading Halcyon"
  if [ "$kind" = cache ]; then rm -rf "$CACHE"; fi
  mkdir -p "$(dirname "$SRC")"
  if ! timeout 600 git clone --quiet "$REPO_URL" "$SRC"; then
    [ "$kind" = fresh ] && rm -rf "$SRC"
    die "git clone failed"
  fi
  [ -f "$SRC/install.sh" ] || { [ "$kind" = fresh ] && rm -rf "$SRC"; die "the download has no install.sh"; }
  local COMMIT; COMMIT=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)
  ok "downloaded ${COMMIT:0:7}"

  # ---- install
  say "Running install.sh"
  withtty bash "$SRC/install.sh" ${ARGS[@]+"${ARGS[@]}"}
  local rc=$?
  if [ "$DRY" = 1 ]; then
    echo; ok "dry run finished: nothing was installed ($CACHE can be deleted)"
    return "$rc"
  fi
  # update.sh compares against this, so the first update after a curl install is exact
  [ -n "$COMMIT" ] && printf '%s\n' "$COMMIT" > "$STATE/installed-commit"
  [ "$kind" = cache ] && rm -rf "$CACHE"

  echo
  if [ "$rc" -eq 0 ]; then
    ok "Halcyon is installed in $RICE"
  else
    warn "install.sh finished with problems (see above). Run it again any time:  $RICE/install.sh"
  fi
  echo "   start it from a tty:   $RICE/launch/halcyon.sh      (or log in again if install.sh set up a session / the lock-screen login)"
  echo "   update later:          $RICE/update.sh   (--check only looks, --changes lists what is new, --rollback goes back)"
  return "$rc"
}

main "$@"; exit $?
