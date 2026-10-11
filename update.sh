#!/usr/bin/env bash
# Halcyon updater: checks https://github.com/X-netrunner/Halcyon and, only if there is something new,
# pulls it and sets it up (install.sh). No new version = nothing is touched.
#
#   ~/.config/Halcyon/update.sh              check, and update when there is a new version
#   ~/.config/Halcyon/update.sh --check      only say whether an update is available (exit 10 = yes, 0 = no)
#   ~/.config/Halcyon/update.sh --changes    list what changed in the new version, change nothing
#   ~/.config/Halcyon/update.sh --force      run the setup again even when already up to date
#   ~/.config/Halcyon/update.sh --rollback   go back to the version you had before the last update (git checkouts)
#   options: --yes (no questions)   --notify (desktop notification with the result)   -q (less output)
#            --no-packages / --no-sysmode / --safety-check / --no-safety-check (passed on to install.sh)   -h
#
# If ~/.config/Halcyon is a git checkout it is updated in place (git pull --rebase --autostash, so your own edits
# stay). If it is a plain copy, the latest version is cloned to ~/.cache/halcyon-update and installed over it
# (install.sh saves the old copy in ~/.config/Halcyon-backups; hypr-user.lua, scheme/current.lua and
# gamemode.conf are kept).
#
# After the island reloads, its log is read: a QML error in the new version is reported at once, with the way back.
# Everything this prints is also saved in ~/.local/state/halcyon/update.log.
#
# The whole script is inside main(): bash reads it completely before running, so the update replacing this very
# file (git pull does) can not confuse the run that is still going.
set -uo pipefail

REPO_URL="${HALCYON_REPO:-https://github.com/X-netrunner/Halcyon}"
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
STATE="$HOME/.local/state/halcyon"
CACHE="$HOME/.cache/halcyon-update"
ISLAND_LOG="$HOME/.cache/island/quickshell-island.log"
CHECK=0; CHANGES=0; FORCE=0; YES=0; ROLLBACK=0; NOTIFY=0; QUIET=0; PASS=()
NET=20                      # seconds a network step may take before it is given up
export GIT_TERMINAL_PROMPT=0

if [ -t 1 ]; then C_H=$'\033[1;36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'; C_B=$'\033[1;32m'; C_0=$'\033[0m'
else C_H=; C_OK=; C_W=; C_E=; C_B=; C_0=; fi
say()  { printf '%s== %s%s\n' "$C_H" "$*" "$C_0"; }
ok()   { [ "$QUIET" = 1 ] || printf '   %s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
info() { [ "$QUIET" = 1 ] || printf '   %s\n' "$*"; }
warn() { printf '   %s!%s %s\n' "$C_W" "$C_0" "$*"; }
note() { [ "$NOTIFY" = 1 ] && command -v notify-send >/dev/null 2>&1 && notify-send -a Halcyon "Halcyon update" "$1" >/dev/null 2>&1; return 0; }
die()  { printf '   %s✗%s %s\n' "$C_E" "$C_0" "$*" >&2; note "Failed: $*"; exit 1; }

usage() { sed -n 2,19p "$0" | sed 's/^# \{0,1\}//'; }

# git with a time limit, so a dead network never hangs the updater
gnet() { timeout "$NET" git "$@"; }

short() { printf '%s' "${1:0:7}"; }

# ---- set up the new files, then make the running desktop notice
finish() {
  say "Reloading"
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v quickshell >/dev/null; then
    local before=0
    [ -f "$ISLAND_LOG" ] && before=$(stat -c %s "$ISLAND_LOG" 2>/dev/null || echo 0)
    # the island reloads itself (and Hyprland + terminal colours) through scripts/reload.sh
    if quickshell ipc -p "$RICE/quickshell/island" call island reload >/dev/null 2>&1; then
      ok "island and Hyprland reloaded"
    else
      command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1
      pkill -f "quickshell -p .*quickshell/island" 2>/dev/null
      sleep 0.5
      if setsid -f "$RICE/scripts/start-shell.sh" island >/dev/null 2>&1; then ok "island restarted, Hyprland reloaded"
      else warn "could not restart the island: log in again, or run $RICE/scripts/start-shell.sh island"; fi
      before=0
    fi
    health "$before"
  else
    ok "not inside a Halcyon session: log in again (or run $RICE/launch/halcyon.sh) to use the new version"
  fi
}

# did the new version load? Read what the island printed since the reload (a QML error means a missing window).
HEALTH_BAD=0
health() {
  local from="$1" size errs
  [ -f "$ISLAND_LOG" ] || return 0
  sleep 4
  size=$(stat -c %s "$ISLAND_LOG" 2>/dev/null || echo 0)
  [ "$size" -lt "$from" ] && from=0                    # the log was cut meanwhile
  errs=$(tail -c +"$((from + 1))" "$ISLAND_LOG" 2>/dev/null | grep -iE 'ERROR|is not a type|unavailable|Cannot assign|PROBLEM' | head -n 8)
  if [ -n "$errs" ]; then
    HEALTH_BAD=1
    warn "the island printed errors while loading the new version:"
    printf '%s\n' "$errs" | sed 's/^/        /'
    warn "full log: $ISLAND_LOG"
    [ -d "$RICE/.git" ] && warn "go back with:  $RICE/update.sh --rollback"
  else
    ok "the island loaded without errors"
  fi
}

# quick sanity pass over the shell scripts that arrived (syntax only, nothing is run)
lint_scripts() {
  local bad=0 f
  while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || { warn "syntax error in ${f#"$RICE"/}"; bad=1; }
  done < <(find "$RICE/scripts" "$RICE/launch" "$RICE/update.sh" "$RICE/install.sh" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
  [ "$bad" = 0 ] && ok "scripts pass a syntax check"
  return 0
}

# the checks halcyon-doctor.sh already knows (only the problem lines are shown)
doctor() {
  [ -x "$RICE/scripts/halcyon-doctor.sh" ] || [ -f "$RICE/scripts/halcyon-doctor.sh" ] || return 0
  local out
  out=$(timeout 60 bash "$RICE/scripts/halcyon-doctor.sh" 2>&1 | grep -iE 'fail|missing|✗|error|not found' | head -n 6)
  if [ -n "$out" ]; then warn "halcyon-doctor reports:"; printf '%s\n' "$out" | sed 's/^/        /'
  else ok "halcyon-doctor has nothing to complain about"; fi
  return 0
}

run_install() {   # run_install <folder with install.sh>
  bash "$1/install.sh" --yes ${PASS[@]+"${PASS[@]}"} || warn "install.sh reported problems (see above)"
}

confirm() {       # confirm "question"  -> 0 = go on
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || { info "run it from a terminal to confirm, or use --yes"; return 1; }
  local r; read -r -p "   $1 [Y/n] " r
  [[ ! "$r" =~ ^[nN] ]]
}

main() {
  for a in "$@"; do
    case "$a" in
      --check) CHECK=1 ;;
      --changes) CHANGES=1; CHECK=1 ;;
      --force) FORCE=1 ;;
      --rollback) ROLLBACK=1 ;;
      --notify) NOTIFY=1 ;;
      -q|--quiet) QUIET=1 ;;
      -y|--yes) YES=1 ;;
      --no-packages|--no-sysmode|--safety-check|--no-safety-check) PASS+=("$a") ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $a (try --help)"; exit 2 ;;
    esac
  done

  [ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root."
  command -v git >/dev/null || die "git is required (sudo pacman -S git)."
  command -v timeout >/dev/null || die "timeout (coreutils) is required."
  mkdir -p "$STATE"

  # one updater at a time (a timer and you at the same moment would both write the same files)
  exec 8>"$STATE/update.lock"
  flock -n 8 || die "another update is already running."

  # keep a log of the run, and still show it
  if [ "$CHECK" = 0 ]; then
    [ "$(stat -c %s "$STATE/update.log" 2>/dev/null || echo 0)" -gt 524288 ] && : > "$STATE/update.log"
    { printf '\n=== %s update.sh %s\n' "$(date '+%F %T')" "$*"; } >> "$STATE/update.log"
    exec > >(tee -a "$STATE/update.log") 2>&1
  fi
  local t0=$SECONDS

  if [ "$ROLLBACK" = 1 ]; then rollback; return; fi

  # ---- what is the newest version on GitHub?
  say "Checking GitHub"
  local ref BRANCH REMOTE
  ref=$(gnet ls-remote --symref "$REPO_URL" HEAD 2>/dev/null) || die "cannot reach $REPO_URL (offline?)"
  BRANCH=$(printf '%s\n' "$ref" | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' | head -n1)
  REMOTE=$(printf '%s\n' "$ref" | awk '$1 != "ref:" && $2 == "HEAD" {print $1; exit}')
  [ -n "$BRANCH" ] && [ -n "$REMOTE" ] || die "could not read the latest version from $REPO_URL"

  if [ -d "$RICE/.git" ]; then update_git; else update_copy; fi

  echo
  printf '%sDone%s in %ss.\n' "$C_B" "$C_0" "$((SECONDS - t0))"
  if [ "$HEALTH_BAD" = 1 ]; then note "Updated, but the island printed errors. Run update.sh --rollback to go back."
  else note "Updated to $(cat "$STATE/installed-commit" 2>/dev/null | cut -c1-7)"; fi
}

# ============================================================ git checkout: update in place
update_git() {
  local cur new
  # a detached HEAD or an unfinished rebase / merge: pulling on top of that makes a mess
  if [ -z "$(git -C "$RICE" symbolic-ref -q HEAD)" ]; then
    die "$RICE is on a detached HEAD. Check a branch out first:  cd $RICE && git switch $BRANCH"
  fi
  local f
  for f in rebase-merge rebase-apply MERGE_HEAD; do
    [ -e "$(git -C "$RICE" rev-parse --git-path "$f")" ] && die "a git $f is unfinished in $RICE. Finish or abort it first:  cd $RICE && git status"
  done

  gnet -C "$RICE" fetch --quiet "$REPO_URL" "$BRANCH" || die "git fetch failed"
  cur=$(git -C "$RICE" rev-parse HEAD)
  new=$(git -C "$RICE" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 1)

  if [ "$new" = 0 ]; then
    ok "Already up to date ($(short "$cur"))"
    [ "$FORCE" = 1 ] && [ "$CHECK" = 0 ] || exit 0
  else
    say "$new new commit(s) on $BRANCH"
    local n=15; [ "$CHANGES" = 1 ] && n=200
    git -C "$RICE" log --format='   %h  %s' -n "$n" HEAD..FETCH_HEAD
    if [ "$CHANGES" = 1 ]; then
      git -C "$RICE" diff --shortstat HEAD FETCH_HEAD | sed 's/^/   /'
      exit 10
    fi
    if [ "$CHECK" = 1 ]; then info "run  $RICE/update.sh  to install them"; exit 10; fi
    local dirty; dirty=$(git -C "$RICE" status --porcelain --untracked-files=no | wc -l)
    [ "$dirty" -gt 0 ] && info "your $dirty local change(s) are kept (stashed while pulling, then put back)"
    say "Pulling"
    if ! git -C "$RICE" pull --rebase --autostash --quiet "$REPO_URL" "$BRANCH"; then
      git -C "$RICE" rebase --abort >/dev/null 2>&1
      die "could not merge the update with your local changes. Nothing was changed; look at it with:  cd $RICE && git status"
    fi
    printf '%s\n' "$cur" > "$STATE/previous-commit"
    ok "now at $(short "$(git -C "$RICE" rev-parse HEAD)")"
    # an edit of yours that clashes with the update: git leaves conflict markers in the file. Never install on top of those:
    # the file goes back to the new upstream version, and your edit stays in the stash.
    local clash f; clash=$(git -C "$RICE" diff --name-only --diff-filter=U)
    if [ -n "$clash" ]; then
      warn "your edit clashes with the update in:"
      while IFS= read -r f; do
        printf '        %s\n' "$f"
        git -C "$RICE" reset -q HEAD -- "$f" 2>/dev/null; git -C "$RICE" checkout -q -- "$f" 2>/dev/null
      done <<< "$clash"
      warn "those files are the new version now. Your edit is saved:  git -C $RICE stash show -p stash@{0}"
      warn "put it back by hand when you want it:  git -C $RICE stash pop   (then fix the markers)"
    fi
  fi

  say "Setting up"
  run_install "$RICE"
  lint_scripts
  git -C "$RICE" rev-parse HEAD > "$STATE/installed-commit"
  finish
  doctor
}

# ============================================================ plain copy: clone the latest and install it
update_copy() {
  local have; have=$(cat "$STATE/installed-commit" 2>/dev/null || true)
  if [ "$have" = "$REMOTE" ] && [ "$FORCE" = 0 ]; then
    ok "Already up to date ($(short "$REMOTE"))"
    exit 0
  fi
  if [ -z "$have" ] && [ -d "$RICE" ] && [ "$FORCE" = 0 ]; then
    warn "$RICE is not a git checkout and no earlier update is recorded, so I cannot tell which version it is."
    if [ "$CHECK" = 1 ]; then info "latest on GitHub: $(short "$REMOTE"). Run  $RICE/update.sh  to install it."; exit 10; fi
    confirm "install the latest version now? (your current copy is backed up first)" || { info "nothing changed."; exit 0; }
  elif [ "$CHECK" = 1 ]; then
    info "update available: $(short "$have") -> $(short "$REMOTE"). Run  $RICE/update.sh  to install it."
    exit 10
  fi

  say "Downloading $(short "$REMOTE")"
  if [ -d "$CACHE/.git" ] && gnet -C "$CACHE" fetch --quiet --depth 1 "$REPO_URL" "$BRANCH" 2>/dev/null \
       && git -C "$CACHE" reset --hard --quiet FETCH_HEAD 2>/dev/null; then :
  else
    rm -rf "$CACHE"
    timeout 300 git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$CACHE" || die "git clone failed"
  fi
  [ -f "$CACHE/install.sh" ] || die "the download has no install.sh"
  ok "downloaded"

  # your own files survive the copy
  local KEEP=(hypr-user.lua scheme/current.lua gamemode.conf gpu.lua special.conf apps.custom gpu-mode autostart.conf)
  local keep f; keep="$(mktemp -d)"
  for f in "${KEEP[@]}"; do
    [ -f "$RICE/$f" ] && { mkdir -p "$keep/$(dirname "$f")"; cp -a "$RICE/$f" "$keep/$f"; }
  done

  say "Setting up"
  run_install "$CACHE"
  for f in "${KEEP[@]}"; do [ -f "$keep/$f" ] && { mkdir -p "$RICE/$(dirname "$f")"; cp -a "$keep/$f" "$RICE/$f"; }; done
  rm -rf "$keep"
  lint_scripts
  git -C "$CACHE" rev-parse HEAD > "$STATE/installed-commit"
  finish
  doctor
}

# ============================================================ back to the version before the last update
rollback() {
  [ -d "$RICE/.git" ] || die "--rollback needs $RICE to be a git checkout. A plain copy keeps its old version in ~/.config/Halcyon-backups (install.sh saved it there)."
  local prev cur
  prev=$(cat "$STATE/previous-commit" 2>/dev/null || true)
  [ -n "$prev" ] && git -C "$RICE" cat-file -e "$prev^{commit}" 2>/dev/null || die "no earlier version is recorded (the last update did not run through update.sh)."
  cur=$(git -C "$RICE" rev-parse HEAD)
  [ "$prev" != "$cur" ] || die "already at that version ($(short "$cur"))."
  say "Rolling back"
  info "$(short "$cur") -> $(short "$prev")   (your uncommitted edits are stashed and put back)"
  git -C "$RICE" log --format='   %h  %s' -n 5 "$prev..$cur"
  confirm "go back to $(short "$prev") now?" || { info "nothing changed."; exit 0; }
  local stashed=0
  if git -C "$RICE" stash push --quiet --include-untracked -m "halcyon update.sh rollback" >/dev/null 2>&1; then stashed=1; fi
  git -C "$RICE" reset --hard --quiet "$prev" || die "git reset failed"
  [ "$stashed" = 1 ] && { git -C "$RICE" stash pop --quiet 2>/dev/null || warn "your stashed edits did not fit back cleanly: git -C $RICE stash list"; }
  say "Setting up"
  run_install "$RICE"
  git -C "$RICE" rev-parse HEAD > "$STATE/installed-commit"
  rm -f "$STATE/previous-commit"
  finish
  printf '%sDone.%s You are back on %s. The update will be offered again; --check shows it.\n' "$C_B" "$C_0" "$(short "$prev")"
}

main "$@"
exit $?
