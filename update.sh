#!/usr/bin/env bash
# Halcyon updater: checks https://github.com/X-netrunner/Halcyon and, only if there is something new,
# pulls it and sets it up (install.sh). No new version = nothing is touched.
#
#   ~/.config/Halcyon/update.sh              check, and update when there is a new version
#   ~/.config/Halcyon/update.sh --check      only say whether an update is available
#   ~/.config/Halcyon/update.sh --force      run the setup again even when already up to date
#   options: --yes (no questions)   --no-packages / --no-sysmode (passed on to install.sh)   -h
#
# If ~/.config/Halcyon is a git checkout it is updated in place (git pull --rebase --autostash, so your own edits
# stay). If it is a plain copy, the latest version is cloned to ~/.cache/halcyon-update and installed over it
# (install.sh saves the old copy in ~/.config/Halcyon-backups; hypr-user.lua, scheme/current.lua and
# gamemode.conf are kept).
set -uo pipefail

REPO_URL="${HALCYON_REPO:-https://github.com/X-netrunner/Halcyon}"
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
STATE="$HOME/.local/state/halcyon"
CACHE="$HOME/.cache/halcyon-update"
CHECK=0; FORCE=0; YES=0; PASS=()

for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    -y|--yes) YES=1 ;;
    --no-packages|--no-sysmode) PASS+=("$a") ;;
    -h|--help) sed -n 2,14p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '   \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root."
command -v git >/dev/null || die "git is required (sudo pacman -S git)."
mkdir -p "$STATE"

# ---- what is the newest version on GitHub?
say "Checking GitHub"
ref=$(git ls-remote --symref "$REPO_URL" HEAD 2>/dev/null) || die "cannot reach $REPO_URL (offline?)"
BRANCH=$(printf '%s\n' "$ref" | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' | head -n1)
REMOTE=$(printf '%s\n' "$ref" | awk '$1 != "ref:" && $2 == "HEAD" {print $1; exit}')
[ -n "$BRANCH" ] && [ -n "$REMOTE" ] || die "could not read the latest version from $REPO_URL"

# ---- set up the new files (install.sh from the given folder), then make the running desktop notice
finish() {
  say "Reloading"
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v quickshell >/dev/null; then
    # the island reloads itself (and Hyprland + terminal colours) through scripts/reload.sh
    if quickshell ipc -p "$RICE/quickshell/island" call island reload >/dev/null 2>&1; then
      ok "island and Hyprland reloaded"
    else
      command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1
      pkill -f "quickshell -p .*quickshell/island" 2>/dev/null
      sleep 0.5
      setsid -f "$RICE/scripts/start-shell.sh" island >/dev/null 2>&1 && ok "island restarted, Hyprland reloaded"
    fi
  else
    ok "not inside a Halcyon session: log in again (or run $RICE/launch/halcyon.sh) to use the new version"
  fi
}

if [ -d "$RICE/.git" ]; then
  # ======================================================== git checkout: update in place
  git -C "$RICE" fetch --quiet "$REPO_URL" "$BRANCH" || die "git fetch failed"
  new=$(git -C "$RICE" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 1)
  if [ "$new" = 0 ]; then
    ok "Already up to date ($(git -C "$RICE" rev-parse --short HEAD))"
    [ "$FORCE" = 1 ] || exit 0
  else
    say "$new new commit(s) on $BRANCH"
    git -C "$RICE" log --oneline HEAD..FETCH_HEAD | head -n 15 | sed 's/^/   /'
    [ "$CHECK" = 1 ] && { echo "   run  $RICE/update.sh  to install them"; exit 0; }
    say "Pulling"
    if ! git -C "$RICE" pull --rebase --autostash --quiet "$REPO_URL" "$BRANCH"; then
      git -C "$RICE" rebase --abort >/dev/null 2>&1
      die "could not merge the update with your local changes. Nothing was changed; look at it with:  cd $RICE && git status"
    fi
    ok "now at $(git -C "$RICE" rev-parse --short HEAD)"
  fi
  [ "$CHECK" = 1 ] && exit 0
  say "Setting up"
  bash "$RICE/install.sh" --yes ${PASS[@]+"${PASS[@]}"} || warn "install.sh reported problems (see above)"
  git -C "$RICE" rev-parse HEAD > "$STATE/installed-commit"
  finish
else
  # ======================================================== plain copy: clone the latest and install it
  have=$(cat "$STATE/installed-commit" 2>/dev/null || true)
  if [ "$have" = "$REMOTE" ] && [ "$FORCE" = 0 ]; then
    ok "Already up to date (${REMOTE:0:7})"
    exit 0
  fi
  if [ -z "$have" ] && [ -d "$RICE" ] && [ "$FORCE" = 0 ]; then
    warn "$RICE is not a git checkout and no earlier update is recorded, so I cannot tell which version it is."
    if [ "$CHECK" = 1 ]; then echo "   latest on GitHub: ${REMOTE:0:7}. Run  $RICE/update.sh  to install it."; exit 0; fi
    if [ "$YES" = 0 ]; then
      [ -t 0 ] || { echo "   run it from a terminal to confirm, or use --yes"; exit 0; }
      read -r -p "   install the latest version now? (your current copy is backed up first) [Y/n] " r
      [[ ! "$r" =~ ^[nN] ]] || { echo "   nothing changed."; exit 0; }
    fi
  elif [ "$CHECK" = 1 ]; then
    echo "   update available: ${have:0:7} -> ${REMOTE:0:7}. Run  $RICE/update.sh  to install it."
    exit 0
  fi

  say "Downloading ${REMOTE:0:7}"
  if [ -d "$CACHE/.git" ] && git -C "$CACHE" fetch --quiet --depth 1 "$REPO_URL" "$BRANCH" 2>/dev/null \
       && git -C "$CACHE" reset --hard --quiet FETCH_HEAD 2>/dev/null; then :
  else
    rm -rf "$CACHE"
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$CACHE" || die "git clone failed"
  fi
  [ -f "$CACHE/install.sh" ] || die "the download has no install.sh"

  # your own files survive the copy
  KEEP=(hypr-user.lua scheme/current.lua gamemode.conf gpu.lua special.conf apps.custom)
  keep="$(mktemp -d)"
  for f in "${KEEP[@]}"; do
    [ -f "$RICE/$f" ] && { mkdir -p "$keep/$(dirname "$f")"; cp -a "$RICE/$f" "$keep/$f"; }
  done

  say "Setting up"
  bash "$CACHE/install.sh" --yes ${PASS[@]+"${PASS[@]}"} || warn "install.sh reported problems (see above)"
  for f in "${KEEP[@]}"; do [ -f "$keep/$f" ] && cp -a "$keep/$f" "$RICE/$f"; done
  rm -rf "$keep"
  git -C "$CACHE" rev-parse HEAD > "$STATE/installed-commit"
  finish
fi

echo
printf '\033[1;32mDone.\033[0m\n'
