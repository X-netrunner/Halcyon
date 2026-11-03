#!/usr/bin/env bash
# Halcyon updater: checks https://github.com/X-netrunner/Halcyon and, only if there is something new,
# pulls it and sets it up (install.sh). No new version = nothing is touched.
#
#   ~/.config/Halcyon/update.sh              check, and update when there is a new version
#   ~/.config/Halcyon/update.sh --check      only say whether an update is available (exit 10 = yes, 0 = no)
#   ~/.config/Halcyon/update.sh --changes    list what changed in the new version, change nothing
#   ~/.config/Halcyon/update.sh --force      run the setup again even when already up to date
#   ~/.config/Halcyon/update.sh --rollback   go back to the version you had before the last update (git checkouts)
#   ~/.config/Halcyon/update.sh --ref <commit|tag>   install exactly that version (git checkout of it, then install.sh --yes with your saved
#                                                    choices). The old version is kept for an automatic way back if the setup or the island's
#                                                    health check fails. Halcyon is PINNED to it: plain updates and "Update all" skip a
#                                                    pinned Halcyon (it is not on a branch, so update.sh could not pull anyway)
#   ~/.config/Halcyon/update.sh --unpin      remove the pin: back on the main branch and updated to the newest version
#   (the pin is one line, HALCYON="<commit>", in ~/.local/state/halcyon/pins.env; the Version Center, >versions, uses these options)
#   options: --yes (no questions)   --notify (desktop notification with the result)   -q (less output)   -h
#            passed on to install.sh:  --no-packages  --no-drivers  --no-aur  --no-apps  --no-tune  --sysmode / --no-sysmode
#            --safety-check / --no-safety-check  --llm[=MODEL] / --no-llm  --whisper[=MODEL] / --no-whisper  --vlm[=MODEL] / --no-vlm  --plymouth / --no-plymouth  --lock-login / --no-lock-login  --tty-autostart
#            --browser ID  --files ID[,ID]  --editor ID[,ID]  --music ID[,ID]  --resources low|medium|high|adaptive  --renderer auto|opengl|vulkan
#            --firewall ai|ufw|none  --antivirus / --no-antivirus
#   --no-extras   do not update LUNA / ai-antivirus / ai-firewall (by default they follow GitHub main on every run, when you chose them)
#            --resource-offset N   (a value goes after a space or an =, see ./install.sh --help)
#   First install on a new machine (nothing to update yet):  curl -fsSLO https://github.com/X-netrunner/Halcyon/releases/latest/download/get.sh && bash get.sh
#
# If ~/.config/Halcyon is a git checkout it is updated in place (git pull --rebase --autostash, so your own edits
# stay). If it is a plain copy, the latest version is cloned to ~/.cache/halcyon-update and installed over it
# (install.sh saves the old copy in ~/.config/Halcyon-backups; hypr-user.lua, scheme/current.lua and
# gamemode.conf are kept).
#
# After the island reloads, its log is read: a QML error in the new version is reported at once, with the way back.
# Everything this prints is also saved in ~/.local/state/halcyon/update.log. LUNA / ai-antivirus / ai-firewall pins are respected by install.sh too.
#
# The whole script is inside main(): bash reads it completely before running, so the update replacing this very
# file (git pull does) can not confuse the run that is still going.
set -uo pipefail

REPO_URL="${HALCYON_REPO:-https://github.com/X-netrunner/Halcyon}"
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
STATE="$HOME/.local/state/halcyon"
CACHE="$HOME/.cache/halcyon-update"
ISLAND_LOG="$HOME/.cache/island/quickshell-island.log"
CHECK=0; CHANGES=0; FORCE=0; YES=0; ROLLBACK=0; NOTIFY=0; QUIET=0; EXTRAS=1; PASS=(); REF=""; UNPIN=0
PINS="$STATE/pins.env"
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

usage() { sed -n '2,/^# If ~\/\.config\/Halcyon is a git checkout/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# git with a time limit, so a dead network never hangs the updater
gnet() { timeout "$NET" git "$@"; }

short() { printf '%s' "${1:0:7}"; }

# pins.env: HALCYON="<commit>" (one line per component; update-extras.sh writes the other three)
pin_get() { [ -f "$PINS" ] && sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$PINS" | tail -n1 || true; }
pin_del() { [ -f "$PINS" ] || return 0; local t; t="$(mktemp)"; grep -v "^$1=" "$PINS" > "$t"; cat "$t" > "$PINS"; rm -f "$t"; }
pin_set() { mkdir -p "$STATE"; pin_del "$1"; printf '%s="%s"\n' "$1" "$2" >> "$PINS"; }

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
      pkill -f "(quickshell|qs) -p .*quickshell/island" 2>/dev/null
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

INSTALL_BAD=0
run_install() {   # run_install <folder with install.sh>
  bash "$1/install.sh" --yes ${PASS[@]+"${PASS[@]}"} || { INSTALL_BAD=1; warn "install.sh reported problems (see above)"; }
}

# LUNA, ai-antivirus and ai-firewall follow GitHub main on their own. When Halcyon has a new version, install.sh updates them;
# when Halcyon is already current this runs instead (only what you chose at install time, only when their source changed).
update_extras() {
  [ "$EXTRAS" = 1 ] && [ "$CHECK" = 0 ] || return 0
  local x="$RICE/scripts/update-extras.sh"
  [ -f "$x" ] || x="$CACHE/scripts/update-extras.sh"
  [ -f "$x" ] || return 0
  say "LUNA, ai-antivirus, ai-firewall"
  bash "$x" $([ "$FORCE" = 1 ] && echo --force) || warn "an extra could not be updated (see above); the installed version stays"
}

confirm() {       # confirm "question"  -> 0 = go on
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || { info "run it from a terminal to confirm, or use --yes"; return 1; }
  local r; read -r -p "   $1 [Y/n] " r
  [[ ! "$r" =~ ^[nN] ]]
}

main() {
  local ALL=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) CHECK=1 ;;
      --changes) CHANGES=1; CHECK=1 ;;
      --force) FORCE=1 ;;
      --rollback) ROLLBACK=1 ;;
      --unpin) UNPIN=1 ;;
      --ref) [ $# -ge 2 ] && [[ "$2" != -* ]] || { echo "--ref needs a commit or a tag (try --help)"; exit 2; }; REF="$2"; shift ;;
      --ref=*) REF="${1#--ref=}" ;;
      --notify) NOTIFY=1 ;;
      --no-extras) EXTRAS=0 ;;
      -q|--quiet) QUIET=1 ;;
      -y|--yes) YES=1 ;;
      # install.sh flags (no value)
      --no-packages|--no-drivers|--no-aur|--no-apps|--no-tune|--sysmode|--no-sysmode|--safety-check|--no-safety-check|--llm|--no-llm|--whisper|--no-whisper|--vlm|--no-vlm|--plymouth|--no-plymouth|--lock-login|--no-lock-login|--tty-autostart|--antivirus|--no-antivirus|--synapse|--no-synapse) PASS+=("$1") ;;
      # install.sh options with a value, as  --opt=value  or  --opt value
      --llm=*|--whisper=*|--vlm=*|--browser=*|--files=*|--editor=*|--music=*|--resources=*|--resource-offset=*|--renderer=*|--firewall=*) PASS+=("$1") ;;
      --browser|--files|--editor|--music|--resources|--resource-offset|--renderer|--firewall)
        [ $# -ge 2 ] && [[ "$2" != -* ]] || { echo "$1 needs a value (try --help)"; exit 2; }
        PASS+=("$1" "$2"); shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
  done

  case "$REF" in ''|*[!A-Za-z0-9._/+-]*) [ -z "$REF" ] || die "that is not a commit or tag name: $REF" ;; esac
  [ -z "$REF" ] || [ "$UNPIN" = 0 ] || die "--ref and --unpin cannot be used together."
  [ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root."
  command -v git >/dev/null || die "git is required (sudo pacman -S git / sudo apt install git)."
  command -v timeout >/dev/null || die "timeout (coreutils) is required."
  mkdir -p "$STATE"

  # one updater at a time (a timer and you at the same moment would both write the same files)
  exec 8>"$STATE/update.lock"
  flock -n 8 || die "another update is already running."

  # keep a log of the run, and still show it
  if [ "$CHECK" = 0 ]; then
    [ "$(stat -c %s "$STATE/update.log" 2>/dev/null || echo 0)" -gt 524288 ] && : > "$STATE/update.log"
    { printf '\n=== %s update.sh %s\n' "$(date '+%F %T')" "${ALL[*]:-}"; } >> "$STATE/update.log"
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

  if [ "$UNPIN" = 1 ]; then pin_del HALCYON; ok "Halcyon is not pinned any more"; fi
  if [ -n "$REF" ]; then
    update_ref || { note "Could not install $REF"; exit 1; }
    printf '%sDone%s in %ss.\n' "$C_B" "$C_0" "$((SECONDS - t0))"
    return 0
  fi
  local pin; pin="$(pin_get HALCYON)"
  if [ -n "$pin" ]; then
    ok "Halcyon is pinned at $(short "$pin") (newest on GitHub: $(short "$REMOTE")): it is not updated. Go back to main with  $RICE/update.sh --unpin"
    update_extras
    exit 0
  fi

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
    if [ "$UNPIN" = 1 ]; then
      say "Back on $BRANCH"
      if git -C "$RICE" show-ref --verify --quiet "refs/heads/$BRANCH"; then git -C "$RICE" switch --quiet "$BRANCH" 2>/dev/null
      else gnet -C "$RICE" fetch --quiet "$REPO_URL" "$BRANCH" && git -C "$RICE" switch --quiet -c "$BRANCH" FETCH_HEAD 2>/dev/null; fi \
        || die "could not switch back to $BRANCH (an edit of yours in the way?). Look at it with:  cd $RICE && git status"
      ok "on $BRANCH"
    else
      die "$RICE is on a detached HEAD. Check a branch out first:  cd $RICE && git switch $BRANCH   (or  update.sh --unpin  when it was pinned)"
    fi
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
    if [ "$FORCE" = 1 ] && [ "$CHECK" = 0 ]; then :; else update_extras; exit 0; fi
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
    update_extras
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

  copy_install "$CACHE"
  doctor
}

# a plain copy: the files of yours survive, install.sh puts the new copy in place (and backs the old one up), then the island is reloaded and read
copy_install() {   # copy_install <a checkout with install.sh>   (INSTALL_BAD / HEALTH_BAD say how it went)
  local KEEP=(hypr-user.lua scheme/current.lua gamemode.conf gpu.lua special.conf apps.custom gpu-mode autostart.conf greeting.conf greeting-custom.txt ai-advisor.conf focus.conf focus-apps.conf remind.conf notes.conf backup-exclude.conf birthdays.txt holidays.txt)
  local keep f; keep="$(mktemp -d)"
  for f in "${KEEP[@]}"; do
    [ -f "$RICE/$f" ] && { mkdir -p "$keep/$(dirname "$f")"; cp -a "$RICE/$f" "$keep/$f"; }
  done
  INSTALL_BAD=0; HEALTH_BAD=0
  say "Setting up"
  run_install "$1"
  for f in "${KEEP[@]}"; do [ -f "$keep/$f" ] && { mkdir -p "$RICE/$(dirname "$f")"; cp -a "$keep/$f" "$RICE/$f"; }; done
  rm -rf "$keep"
  lint_scripts
  git -C "$1" rev-parse HEAD > "$STATE/installed-commit"
  finish
  [ "$INSTALL_BAD" = 0 ] && [ "$HEALTH_BAD" = 0 ]
}

# ============================================================ --ref: one exact version (a commit or a tag), pinned
# Git checkout: the working tree goes to that commit (detached HEAD; your edits are stashed and put back), install.sh runs, the island's
# health is read. A plain copy: the version is cloned to ~/.cache/halcyon-update-ref and installed over it (install.sh backs the old copy up).
# When the setup or the health check fails, the version you had is installed again by the same steps.
ref_checkout() {   # ref_checkout <sha> [branch]   (git checkout only; the setup is run by the caller)
  local sha="$1" br="${2:-}" before after stashed=0
  before=$(git -C "$RICE" rev-parse -q --verify refs/stash 2>/dev/null || true)
  git -C "$RICE" stash push --quiet --include-untracked -m "halcyon update.sh --ref" >/dev/null 2>&1
  after=$(git -C "$RICE" rev-parse -q --verify refs/stash 2>/dev/null || true)
  [ -n "$after" ] && [ "$after" != "$before" ] && stashed=1
  if [ -n "$br" ]; then git -C "$RICE" switch --quiet "$br"; else git -C "$RICE" -c advice.detachedHead=false checkout --quiet --detach "$sha"; fi || {
    [ "$stashed" = 1 ] && git -C "$RICE" stash pop --quiet 2>/dev/null; return 1; }
  [ "$stashed" = 1 ] && { git -C "$RICE" stash pop --quiet 2>/dev/null || warn "your stashed edits did not fit back cleanly: git -C $RICE stash list"; }
  return 0
}
ref_setup_git() {  # ref_setup_git <sha> [branch] -> 0 when the setup and the health check are fine
  ref_checkout "$1" "${2:-}" || { warn "could not check $(short "$1") out"; return 1; }
  INSTALL_BAD=0; HEALTH_BAD=0
  say "Setting up"
  run_install "$RICE"
  lint_scripts
  printf '%s\n' "$1" > "$STATE/installed-commit"
  finish
  [ "$INSTALL_BAD" = 0 ] && [ "$HEALTH_BAD" = 0 ]
}
update_ref() {
  local sha cur br pinbefore; pinbefore="$(pin_get HALCYON)"
  if [ -d "$RICE/.git" ]; then
    local f
    for f in rebase-merge rebase-apply MERGE_HEAD; do
      [ -e "$(git -C "$RICE" rev-parse --git-path "$f")" ] && die "a git $f is unfinished in $RICE. Finish or abort it first:  cd $RICE && git status"
    done
    gnet -C "$RICE" fetch --quiet --tags --force "$REPO_URL" "+refs/heads/$BRANCH:refs/halcyon/upstream" || warn "could not fetch: only the history already here is searched"
    sha=$(git -C "$RICE" rev-parse --verify --quiet "$REF^{commit}") || die "$REF is not a commit or tag of $REPO_URL"
    cur=$(git -C "$RICE" rev-parse HEAD); br=$(git -C "$RICE" symbolic-ref -q --short HEAD || true)
    if [ "$cur" = "$sha" ] && [ "$FORCE" = 0 ]; then pin_set HALCYON "$sha"; ok "already at $(short "$sha"): pinned there"; return 0; fi
    say "Version $(short "$sha")  (now $(short "$cur"))"
    git -C "$RICE" log --format='   %h  %s' -n 1 "$sha"
    git -C "$RICE" diff --shortstat "$cur" "$sha" | sed 's/^/   /'
    git -C "$RICE" merge-base --is-ancestor "$sha" "$cur" 2>/dev/null && warn "this version is OLDER than the one installed: settings written by the newer one may not be understood"
    confirm "install $(short "$sha") now? (your edits are stashed and put back; a way back is kept)" || { info "nothing changed."; return 0; }
    printf '%s\n' "$cur" > "$STATE/previous-commit"
    if ref_setup_git "$sha"; then
      pin_set HALCYON "$sha"
      ok "Halcyon is at $(short "$sha") and pinned there"
      return 0
    fi
    warn "that version did not set up cleanly: putting $(short "$cur") back"
    local back=""; [ -n "$br" ] && [ "$(git -C "$RICE" rev-parse "$br" 2>/dev/null)" = "$cur" ] && back="$br"
    ref_setup_git "$cur" "$back" && ok "$(short "$cur") is back" || warn "the way back did not set up cleanly either. By hand:  cd $RICE && git switch ${br:-$BRANCH} && ./install.sh --yes"
    [ -n "$pinbefore" ] && pin_set HALCYON "$pinbefore" || pin_del HALCYON
    return 1
  fi
  # a plain copy
  local have rc; have=$(cat "$STATE/installed-commit" 2>/dev/null || true)
  rm -rf "$CACHE-ref"
  timeout 300 git clone --quiet "$REPO_URL" "$CACHE-ref" || die "git clone failed"
  sha=$(git -C "$CACHE-ref" rev-parse --verify --quiet "$REF^{commit}") || die "$REF is not a commit or tag of $REPO_URL"
  if [ "$have" = "$sha" ] && [ "$FORCE" = 0 ]; then pin_set HALCYON "$sha"; ok "already at $(short "$sha"): pinned there"; return 0; fi
  say "Version $(short "$sha")  (now $([ -n "$have" ] && short "$have" || echo unknown))"
  git -C "$CACHE-ref" log --format='   %h  %s' -n 1 "$sha"
  [ -n "$have" ] && git -C "$CACHE-ref" merge-base --is-ancestor "$sha" "$have" 2>/dev/null && warn "this version is OLDER than the one installed"
  confirm "install $(short "$sha") now? (install.sh saves your copy in ~/.config/Halcyon-backups first)" || { info "nothing changed."; return 0; }
  [ -n "$have" ] && printf '%s\n' "$have" > "$STATE/previous-commit"
  git -C "$CACHE-ref" -c advice.detachedHead=false checkout --quiet --detach "$sha"
  if copy_install "$CACHE-ref"; then pin_set HALCYON "$sha"; ok "Halcyon is at $(short "$sha") and pinned there"; return 0; fi
  warn "that version did not set up cleanly"
  if [ -n "$have" ] && git -C "$CACHE-ref" rev-parse --verify --quiet "$have^{commit}" >/dev/null; then
    warn "putting $(short "$have") back"
    git -C "$CACHE-ref" -c advice.detachedHead=false checkout --quiet --detach "$have" && copy_install "$CACHE-ref" && ok "$(short "$have") is back" || warn "the way back did not set up cleanly either: the copy in ~/.config/Halcyon-backups is the one you had"
  else warn "the version you had is not recorded: the copy in ~/.config/Halcyon-backups is the one you had"; fi
  [ -n "$pinbefore" ] && pin_set HALCYON "$pinbefore" || pin_del HALCYON
  return 1
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
  # `git stash push` also exits 0 when there was NOTHING to stash. The old code then ran `stash pop` anyway and put back the newest
  # OLDER stash: for example the "your edit clashes with the update" stash an earlier update.sh run told you to keep.
  local stashed=0 before after
  before=$(git -C "$RICE" rev-parse -q --verify refs/stash 2>/dev/null || true)
  git -C "$RICE" stash push --quiet --include-untracked -m "halcyon update.sh rollback" >/dev/null 2>&1
  after=$(git -C "$RICE" rev-parse -q --verify refs/stash 2>/dev/null || true)
  [ -n "$after" ] && [ "$after" != "$before" ] && stashed=1
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
