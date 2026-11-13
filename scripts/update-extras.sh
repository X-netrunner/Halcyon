#!/usr/bin/env bash
# Updates Halcyon's companion programs to the newest main: LUNA, ai-antivirus, ai-firewall, Halcyon Files (halcyon-fm).
# update.sh runs this when Halcyon itself is already current (when Halcyon has a new version, install.sh does the same work).
# It only touches what you chose at install time (~/.local/state/island/install-choices.env: LUNA, ANTIVIRUS, FIREWALL=ai, FM),
# and only rebuilds one when its source changed. The old build output is deleted first.
#
#   update-extras.sh            update what is installed and chosen
#   update-extras.sh --force    rebuild even when nothing changed
#   update-extras.sh --dry-run  say what would happen
#   update-extras.sh --only luna|ai-antivirus|ai-firewall|halcyon-fm    only that one (repeat the option for two)
#   update-extras.sh --only luna --ref <commit|tag>          install exactly that version of that one (needs --only, one component).
#                                                            The managed clone is checked out at it, built like an update, the stamp written;
#                                                            the component is pinned (~/.local/state/halcyon/pins.env) so later updates leave it alone.
#   update-extras.sh --unpin luna                            remove the pin (the next update follows main again)
#   update-extras.sh --ignore-pins                           update a pinned component to main as well (the pin is removed)
#   update-extras.sh --restore luna                          put back the copy kept before the last install (no rebuild; exit 3 = none kept)
#
# A pinned component (pins.env) is skipped by every plain run. The Version Center (>versions) calls this script for all of it.
# Sources: GitHub main, in ~/.local/src/<name>. Override with LUNA_SRC / AV_SRC / AIFW_SRC (a local folder is built as it is,
# no git), or by putting ai-antivirus/ ai-firewall/ LUNA-AI/ Filemanager/ folders next to the Halcyon folder (a bundle). With --ref the managed
# clone is always used (a local folder has no history to pick from). Other repositories: LUNA_REPO / AV_REPO / AIFW_REPO / FM_REPO.
set -uo pipefail

FORCE=0 DRY=0 REF="" IGNORE_PINS=0 ONLY=() UNPIN=() RESTORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --ignore-pins) IGNORE_PINS=1 ;;
    -y|--yes|-q) ;;
    --only) [ $# -ge 2 ] || { echo "--only needs luna, ai-antivirus, ai-firewall or halcyon-fm" >&2; exit 2; }
            case "$2" in luna|ai-antivirus|ai-firewall|halcyon-fm) ONLY+=("$2") ;; *) echo "unknown component: $2" >&2; exit 2 ;; esac; shift ;;
    --ref)  [ $# -ge 2 ] && [[ "$2" != -* ]] || { echo "--ref needs a commit or a tag" >&2; exit 2; }; REF="$2"; shift ;;
    --restore) [ $# -ge 2 ] || { echo "--restore needs a component" >&2; exit 2; }; RESTORE="$2"; shift ;;
    --unpin) [ $# -ge 2 ] || { echo "--unpin needs a component" >&2; exit 2; }; UNPIN+=("$2"); shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$REF" ] && [ "${#ONLY[@]}" -ne 1 ]; then echo "--ref needs exactly one --only component" >&2; exit 2; fi
case "$REF" in *[!A-Za-z0-9._/+-]*) echo "that is not a commit or tag name" >&2; exit 2 ;; esac
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$(dirname "$HERE")"
SRC="$HOME/.local/src"; STATE="$HOME/.local/state/island"; BUILD="$HOME/.cache/halcyon-build"
HSTATE="$HOME/.local/state/halcyon"            # pins.env, the saved previous versions (prev/)
PINS="$HSTATE/pins.env"; PREV="$HSTATE/prev"
CH="$STATE/install-choices.env"
NET=20                                          # seconds a network step may take (the same limit update.sh uses)
export GIT_TERMINAL_PROMPT=0
AV_BIN="${AV_BIN:-/usr/bin/ai-antivirus}"
AIFW_BIN="${AIFW_BIN:-/usr/local/bin/ai-firewall}"; AIFW_UNIT="${AIFW_UNIT:-/etc/systemd/system/ai-firewall.service}"
LUNA_REPO="${LUNA_REPO:-https://github.com/X-netrunner/LUNA-AI.git}"
AV_REPO="${AV_REPO:-https://github.com/X-netrunner/ai-antivirus}"
AIFW_REPO="${AIFW_REPO:-https://github.com/X-netrunner/ai-firewall.git}"
FM_REPO="${FM_REPO:-https://github.com/X-netrunner/Filemanager.git}"
choice() { [ -f "$CH" ] && sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$CH" | tail -n1 || true; }

say()  { printf '   == %s\n' "$*"; }
ok()   { printf '   ✓ %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*" >&2; }
run()  { printf '     $ %s\n' "$*"; [ "$DRY" = 1 ] || "$@"; }
gnet() { timeout "$NET" git "$@"; }

# ---- pins: one line per component, KEY="full commit"  (KEY = LUNA | ANTIVIRUS | FIREWALL | FM, the names install-choices.env uses)
pin_get() { [ -f "$PINS" ] && sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$PINS" | tail -n1 || true; }
pin_del() { [ -f "$PINS" ] || return 0; local t; t="$(mktemp)"; grep -v "^$1=" "$PINS" > "$t"; cat "$t" > "$PINS"; rm -f "$t"; }
pin_set() { mkdir -p "$HSTATE"; pin_del "$1"; printf '%s="%s"\n' "$1" "$2" >> "$PINS"; }

wanted() { [ "${#ONLY[@]}" -eq 0 ] && return 0; local c; for c in "${ONLY[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }
# a pinned component is left alone by a plain run (no --ref, no --ignore-pins)
skip_pinned() { # skip_pinned KEY LABEL
  local p; p="$(pin_get "$1")"
  [ -n "$p" ] && [ -z "$REF" ] && [ "$IGNORE_PINS" = 0 ] || return 1
  ok "$2 is pinned at ${p:0:7}: left as it is (unpin it in the Version Center, or: update-extras.sh --unpin ...)"
  return 0
}
# the folder a component is built from: an explicit / bundle folder, unless a version was asked for (a bundle has no history)
pick() { # pick VAR-VALUE FOLDERNAME -> a local folder (explicit, or next to Halcyon), else empty = GitHub
  [ -z "$REF" ] || return 0
  if [ -n "$1" ]; then printf '%s' "$1"; elif [ -f "$BUNDLE/$2/Cargo.toml" ]; then printf '%s' "$BUNDLE/$2"; fi
}
clone_if_missing() { # clone_if_missing DIR REPO
  [ -d "$1/.git" ] && return 0
  mkdir -p "$SRC"; run timeout 300 git clone --quiet "$2" "$1" >&2
}
# managed clone forced to the newest main, or to the version asked for (--ref); echoes the folder
sync_main() { # sync_main NAME LOCAL REPO
  local name="$1" local_dir="$2" repo="$3" d="$SRC/$1"
  if [ -n "$local_dir" ]; then printf '%s' "$local_dir"; return 0; fi
  clone_if_missing "$d" "$repo" || return 1
  if [ "$DRY" != 1 ]; then
    if [ -n "$REF" ]; then
      local sha
      gnet -C "$d" fetch --quiet --tags --force origin '+refs/heads/*:refs/remotes/origin/*' >&2 || warn "$name: could not reach $repo, using the history already here"
      sha="$(git -C "$d" rev-parse --verify --quiet "$REF^{commit}" || git -C "$d" rev-parse --verify --quiet "origin/$REF^{commit}")" \
        || { warn "$name: $REF is not a commit or tag of $repo"; return 1; }
      git -C "$d" -c advice.detachedHead=false checkout --quiet -f --detach "$sha" >&2 || return 1
    else
      gnet -C "$d" fetch --quiet origin main && git -C "$d" checkout --quiet -f -B main FETCH_HEAD >&2 || return 1
    fi
  fi
  printf '%s' "$d"
}
# the same stamp install.sh saves (LUNA: the commit; the other two: the commit + a hash of uncommitted changes), so neither rebuilds the other's work
stamp_of() {
  if git -C "$1" rev-parse HEAD >/dev/null 2>&1; then
    if [ "${2:-}" = full ]; then echo "$(git -C "$1" rev-parse HEAD)-$(git -C "$1" status --porcelain 2>/dev/null | sha256sum | cut -c1-12)"; else git -C "$1" rev-parse HEAD; fi
  else find "$1" -path "$1/target" -prune -o -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1; fi
}
sha_of_stamp() { printf '%s' "${1%%-*}"; }
# after a good install: the pin (a version asked for), or no pin (a normal update to main), and the hash of the installed program
settle() { # settle KEY NOW
  [ "$DRY" = 1 ] && return 0
  if [ -n "$REF" ]; then pin_set "$1" "$(sha_of_stamp "$2")"; elif [ "$IGNORE_PINS" = 1 ]; then pin_del "$1"; fi
}
record_bin() { [ "$DRY" = 1 ] || { mkdir -p "$HSTATE"; sha256sum "$2" 2>/dev/null | cut -d' ' -f1 > "$HSTATE/bin-$1.sha"; }; }
# keep what is installed now, so a failed health check can put it back without a rebuild (the Version Center calls --restore)
keep_prev() { # keep_prev NAME STAMPFILE FILE...
  [ "$DRY" = 1 ] && return 0
  local n="$1" st="$2"; shift 2
  [ -f "$st" ] || return 0
  rm -rf "$PREV/$n"; mkdir -p "$PREV/$n"
  cp -a "$st" "$PREV/$n/stamp" 2>/dev/null
  local f; for f in "$@"; do [ -f "$f" ] && cp -a "$f" "$PREV/$n/" 2>/dev/null; done
  return 0
}

FAILED=0

# ---------------------------------------------------------------- --unpin / --restore (no build)
for c in ${UNPIN[@]+"${UNPIN[@]}"}; do
  case "$c" in luna) pin_del LUNA ;; ai-antivirus) pin_del ANTIVIRUS ;; ai-firewall) pin_del FIREWALL ;; halcyon-fm) pin_del FM ;; *) echo "unknown component: $c" >&2; exit 2 ;; esac
  ok "$c: unpinned (the next update follows main)"
done
if [ "${#UNPIN[@]}" -gt 0 ] && [ "${#ONLY[@]}" -eq 0 ]; then exit 0; fi

# ---------------------------------------------------------------- --restore: what keep_prev saved before the last install
do_restore() {
  local n="$1" p="$PREV/$1" u f
  [ -f "$p/stamp" ] || { warn "$n: no earlier version was kept"; return 3; }
  case "$n" in
    luna)
      [ -f "$p/luna" ] || return 3
      run install -Dm755 "$p/luna" "$HOME/.local/bin/luna" || return 1
      [ "$DRY" = 1 ] || { cp -a "$p/stamp" "$STATE/luna-rev"; record_bin luna "$HOME/.local/bin/luna"; }
      for u in luna-daemon luna-wake; do systemctl --user is-active --quiet "$u.service" 2>/dev/null && run systemctl --user restart "$u.service"; done ;;
    halcyon-fm)
      [ -f "$p/halcyon-fm" ] || return 3
      run install -Dm755 "$p/halcyon-fm" "$HOME/.local/bin/halcyon-fm" || return 1
      [ "$DRY" = 1 ] || { cp -a "$p/stamp" "$STATE/fm-rev"; record_bin halcyon-fm "$HOME/.local/bin/halcyon-fm"; } ;;
    ai-firewall)
      [ -f "$p/$(basename "$AIFW_BIN")" ] || return 3
      run sudo install -Dm755 "$p/$(basename "$AIFW_BIN")" "$AIFW_BIN" || return 1
      [ -f "$p/$(basename "$AIFW_UNIT")" ] && run sudo install -Dm644 "$p/$(basename "$AIFW_UNIT")" "$AIFW_UNIT"
      run sudo systemctl daemon-reload
      systemctl is-active --quiet ai-firewall.service && run sudo systemctl restart ai-firewall.service
      [ "$DRY" = 1 ] || { cp -a "$p/stamp" "$STATE/aifw-src"; record_bin ai-firewall "$AIFW_BIN"; } ;;
    ai-antivirus)
      f="$(ls -t "$p"/ai-antivirus-[0-9]*.pkg.tar.* 2>/dev/null | head -1)"
      [ -n "$f" ] || { warn "ai-antivirus: the previous package was not kept"; return 3; }
      local active=() s
      for s in engined sensord responderd analyzer; do systemctl is-active --quiet "ai-antivirus-$s.service" 2>/dev/null && active+=("ai-antivirus-$s"); done
      run sudo pacman -U --noconfirm "$f" || return 1
      for s in ${active[@]+"${active[@]}"}; do run sudo systemctl restart "$s.service"; done
      [ "$DRY" = 1 ] || { cp -a "$p/stamp" "$STATE/ai-antivirus-src"; record_bin ai-antivirus "$AV_BIN"; } ;;
    *) echo "unknown component: $n" >&2; return 2 ;;
  esac
  ok "$n: the earlier version is back ($(cut -c1-7 "$p/stamp"))"
}
if [ -n "$RESTORE" ]; then do_restore "$RESTORE"; exit $?; fi

# ---------------------------------------------------------------- LUNA
do_luna() {
  [ "$(choice LUNA)" = yes ] || return 0
  say "LUNA"
  skip_pinned LUNA LUNA && return 0
  local d u now st="$STATE/luna-rev" lbin="$HOME/.local/bin/luna"
  d="$(sync_main LUNA-AI "$(pick "${LUNA_SRC:-}" LUNA-AI)" "$LUNA_REPO")" || { warn "LUNA: could not fetch ${REF:-main}"; FAILED=1; return 0; }
  [ -f "$d/Cargo.toml" ] || return 0
  now="$(stamp_of "$d")"
  if [ "$FORCE" = 0 ] && [ -x "$lbin" ] && [ "$(cat "$st" 2>/dev/null)" = "$now" ]; then settle LUNA "$now"; ok "LUNA is up to date (${now:0:7})"; return 0; fi
  if ! command -v cargo >/dev/null 2>&1; then warn "LUNA: cargo is missing"; FAILED=1; return 0; fi
  [ -n "$(git -C "$d" rev-parse HEAD 2>/dev/null)" ] && [ -z "$(pick "${LUNA_SRC:-}" LUNA-AI)" ] && run git -C "$d" clean -fdxq
  rm -rf "$BUILD/luna"
  keep_prev luna "$st" "$lbin"
  if run env CARGO_TARGET_DIR="$BUILD/luna" cargo build --release --locked --manifest-path "$d/Cargo.toml" \
     && run install -Dm755 "$BUILD/luna/release/luna" "$lbin"; then
    [ "$DRY" = 1 ] || { mkdir -p "$STATE"; printf '%s\n' "$now" > "$st"; record_bin luna "$lbin"; rm -rf "$BUILD/luna"; }
    for u in luna-daemon luna-wake; do systemctl --user is-active --quiet "$u.service" 2>/dev/null && run systemctl --user restart "$u.service"; done
    settle LUNA "$now"
    ok "LUNA updated to ${now:0:7}"
  else warn "LUNA did not build: the installed version stays"; FAILED=1; fi
}

# ---------------------------------------------------------------- Halcyon Files (the file manager, halcyon-fm)
# Built like LUNA: a Cargo project that makes a program called halcyon-fm. An empty repository (no commits yet) is not a failure.
do_fm() {
  [ "$(choice FM)" = yes ] || return 0
  say "Halcyon Files"
  skip_pinned FM "Halcyon Files" && return 0
  local d now heads rc local_dir st="$STATE/fm-rev" fbin="$HOME/.local/bin/halcyon-fm" lock=()
  local_dir="$(pick "${FM_SRC:-}" Filemanager)"
  if [ -z "$local_dir" ] && [ "$DRY" != 1 ]; then
    heads="$(gnet ls-remote --heads "$FM_REPO" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$heads" ]; then ok "Halcyon Files: $FM_REPO has no commits yet, nothing to update"; return 0; fi
  fi
  d="$(sync_main Filemanager "$local_dir" "$FM_REPO")" || { warn "Halcyon Files: could not fetch ${REF:-main}"; FAILED=1; return 0; }
  [ -f "$d/Cargo.toml" ] || { warn "Halcyon Files: no Cargo.toml in $d (it has to be a Cargo project)"; return 0; }
  now="$(stamp_of "$d")"
  if [ "$FORCE" = 0 ] && [ -x "$fbin" ] && [ "$(cat "$st" 2>/dev/null)" = "$now" ]; then settle FM "$now"; ok "Halcyon Files is up to date (${now:0:7})"; return 0; fi
  if ! command -v cargo >/dev/null 2>&1; then warn "Halcyon Files: cargo is missing"; FAILED=1; return 0; fi
  [ -n "$(git -C "$d" rev-parse HEAD 2>/dev/null)" ] && [ -z "$local_dir" ] && run git -C "$d" clean -fdxq
  rm -rf "$BUILD/halcyon-fm"
  keep_prev halcyon-fm "$st" "$fbin"
  [ -f "$d/Cargo.lock" ] && lock=(--locked)
  if run env CARGO_TARGET_DIR="$BUILD/halcyon-fm" cargo build --release ${lock[@]+"${lock[@]}"} --manifest-path "$d/Cargo.toml" \
     && run install -Dm755 "$BUILD/halcyon-fm/release/halcyon-fm" "$fbin"; then
    [ "$DRY" = 1 ] || { mkdir -p "$STATE"; printf '%s\n' "$now" > "$st"; record_bin halcyon-fm "$fbin"; rm -rf "$BUILD/halcyon-fm"; }
    settle FM "$now"
    ok "Halcyon Files updated to ${now:0:7}"
  else warn "Halcyon Files did not build (or made no program called halcyon-fm): the installed version stays"; FAILED=1; fi
}

# ---------------------------------------------------------------- ai-antivirus (pacman package)
# The Security center (and its AI: reading, acknowledging, the action log) needs group ai-antivirus. Checked on every update, also
# when nothing is rebuilt, so an install from before that rule gets full access without anyone typing usermod. No logout needed:
# the shell reads through `sg ai-antivirus` until the next login.
av_grant() {
  local u g need=""; u="$(id -un)"
  [ "$(id -u)" -ne 0 ] || return 0
  pacman -Q ai-antivirus >/dev/null 2>&1 || return 0
  for g in ai-antivirus ai-antivirus-notify; do
    getent group "$g" >/dev/null 2>&1 || continue
    id -nG "$u" | tr ' ' '\n' | grep -qx "$g" || need="${need:+$need,}$g"
  done
  [ -z "$need" ] || { run sudo usermod -aG "$need" "$u" && ok "ai-antivirus: $u was added to $need (full access to the Security center)"; }
}
do_av() {
  av_grant
  [ "$(choice ANTIVIRUS)" = yes ] || { [ -z "$(choice ANTIVIRUS)" ] && [ "$(choice SYNAPSE)" = yes ]; } || return 0
  say "ai-antivirus"
  skip_pinned ANTIVIRUS ai-antivirus && return 0
  if ! command -v makepkg >/dev/null 2>&1; then warn "ai-antivirus: makepkg is missing (Arch only)"; FAILED=1; return 0; fi
  local d now st="$STATE/ai-antivirus-src" pkg s active=()
  d="$(sync_main ai-antivirus "$(pick "${AV_SRC:-}" ai-antivirus)" "$AV_REPO")" || { warn "ai-antivirus: could not fetch ${REF:-main}"; FAILED=1; return 0; }
  [ -f "$d/Cargo.toml" ] || return 0
  now="$(stamp_of "$d" full)"
  if [ "$FORCE" = 0 ] && pacman -Q ai-antivirus >/dev/null 2>&1 && [ "$(cat "$st" 2>/dev/null)" = "$now" ]; then settle ANTIVIRUS "$now"; ok "ai-antivirus is up to date (${now:0:7})"; return 0; fi
  # the eBPF object: rebuilt when bpf-linker is there, else the installed one is reused
  if command -v bpf-linker >/dev/null 2>&1; then run bash -c "cd '$d' && cargo xtask build-ebpf --release" || warn "eBPF rebuild failed"
  elif [ ! -f "$d/target/bpf/ai-antivirus-ebpf.o" ] && [ -f /usr/lib/ai-antivirus/ai-antivirus-ebpf.o ]; then
    warn "bpf-linker missing: reusing the installed eBPF object"; run mkdir -p "$d/target/bpf"; run cp /usr/lib/ai-antivirus/ai-antivirus-ebpf.o "$d/target/bpf/ai-antivirus-ebpf.o"
  fi
  # the package that is installed now is kept (a failed health check puts it back with pacman -U, no rebuild), then the old ones go
  if [ "$DRY" != 1 ] && pacman -Q ai-antivirus >/dev/null 2>&1; then
    local iv; iv="$(pacman -Q ai-antivirus | awk '{print $2}')"
    pkg="$(ls -t "$d"/packaging/arch/ai-antivirus-"$iv"-*.pkg.tar.* 2>/dev/null | head -1)"
    keep_prev ai-antivirus "$st" ${pkg:+"$pkg"}
  fi
  run bash -c "find '$d/packaging/arch' -maxdepth 1 -name '*.pkg.tar.*' -delete; rm -rf '$d/packaging/arch/pkg'"
  for s in engined sensord responderd analyzer; do systemctl is-active --quiet "ai-antivirus-$s.service" 2>/dev/null && active+=("ai-antivirus-$s"); done
  if run bash -c "cd '$d/packaging/arch' && makepkg -f --noconfirm"; then
    pkg="$(ls -t "$d"/packaging/arch/ai-antivirus-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)"
    if [ "$DRY" = 1 ] || { [ -n "$pkg" ] && run sudo pacman -U --noconfirm "$pkg"; }; then
      for s in ${active[@]+"${active[@]}"}; do run sudo systemctl restart "$s.service"; done
      [ "$DRY" = 1 ] || { mkdir -p "$STATE"; printf '%s\n' "$now" > "$st"; record_bin ai-antivirus "$AV_BIN"; }
      settle ANTIVIRUS "$now"
      ok "ai-antivirus updated to ${now:0:7}"
    else warn "ai-antivirus: install failed, the installed version stays"; FAILED=1; fi
  else warn "ai-antivirus did not build: the installed version stays"; FAILED=1; fi
}

# ---------------------------------------------------------------- ai-firewall
do_fw() {
  [ "$(choice FIREWALL)" = ai ] || return 0
  say "ai-firewall"
  skip_pinned FIREWALL ai-firewall && return 0
  if pacman -Q ai-firewall >/dev/null 2>&1 || pacman -Q ai-firewall-git >/dev/null 2>&1; then ok "ai-firewall is a pacman package: pacman keeps it updated"; return 0; fi
  local d now st="$STATE/aifw-src"
  d="$(sync_main ai-firewall "$(pick "${AIFW_SRC:-}" ai-firewall)" "$AIFW_REPO")" || { warn "ai-firewall: could not fetch ${REF:-main}"; FAILED=1; return 0; }
  [ -f "$d/Cargo.toml" ] || return 0
  now="$(stamp_of "$d" full)"
  if [ "$FORCE" = 0 ] && [ -x "$AIFW_BIN" ] && [ "$(cat "$st" 2>/dev/null)" = "$now" ]; then settle FIREWALL "$now"; ok "ai-firewall is up to date (${now:0:7})"; return 0; fi
  if ! command -v rustup >/dev/null 2>&1 || ! command -v bpf-linker >/dev/null 2>&1; then warn "ai-firewall needs rustup (nightly + rust-src) and bpf-linker: the installed version stays"; FAILED=1; return 0; fi
  rm -rf "$BUILD/ai-firewall"
  keep_prev ai-firewall "$st" "$AIFW_BIN" "$AIFW_UNIT"
  if run env CARGO_TARGET_DIR="$BUILD/ai-firewall" cargo +nightly build --release --locked --manifest-path "$d/Cargo.toml" -p ai-firewall \
     && run sudo install -Dm755 "$BUILD/ai-firewall/release/ai-firewall" "$AIFW_BIN" \
     && run sudo install -Dm644 "$d/packaging/ai-firewall.service" "$AIFW_UNIT"; then
    run sudo systemctl daemon-reload
    # filtering never stops during a restart (pinned bpf links); a stopped firewall is not started behind your back
    systemctl is-active --quiet ai-firewall.service && run sudo systemctl restart ai-firewall.service
    [ "$DRY" = 1 ] || { mkdir -p "$STATE"; printf '%s\n' "$now" > "$st"; record_bin ai-firewall "$AIFW_BIN"; rm -rf "$BUILD/ai-firewall"; }
    settle FIREWALL "$now"
    ok "ai-firewall updated to ${now:0:7}"
  else warn "ai-firewall did not build: the installed version stays"; FAILED=1; fi
}

wanted luna && do_luna
wanted ai-antivirus && do_av
wanted ai-firewall && do_fw
wanted halcyon-fm && do_fm

[ "$FAILED" = 0 ]
