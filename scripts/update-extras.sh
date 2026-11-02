#!/usr/bin/env bash
# Updates Halcyon's three companion programs to the newest main: LUNA, ai-antivirus, ai-firewall.
# update.sh runs this when Halcyon itself is already current (when Halcyon has a new version, install.sh does the same work).
# It only touches what you chose at install time (~/.local/state/island/install-choices.env: LUNA, ANTIVIRUS, FIREWALL=ai),
# and only rebuilds one when its source changed. The old build output is deleted first.
#
#   update-extras.sh            update what is installed and chosen
#   update-extras.sh --force    rebuild even when nothing changed
#   update-extras.sh --dry-run  say what would happen
#
# Sources: GitHub main, in ~/.local/src/<name>. Override with LUNA_SRC / AV_SRC / AIFW_SRC (a local folder is built as it is,
# no git), or by putting ai-antivirus/ ai-firewall/ LUNA-AI/ folders next to the Halcyon folder (a bundle).
set -uo pipefail

FORCE=0 DRY=0
for a in "$@"; do case "$a" in --force) FORCE=1 ;; --dry-run) DRY=1 ;; -y|--yes|-q) ;; -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; *) echo "unknown option: $a" >&2; exit 2 ;; esac; done
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$(dirname "$HERE")"
SRC="$HOME/.local/src"; STATE="$HOME/.local/state/island"; BUILD="$HOME/.cache/halcyon-build"
CH="$STATE/install-choices.env"
choice() { [ -f "$CH" ] && sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$CH" | tail -n1 || true; }

say()  { printf '   == %s\n' "$*"; }
ok()   { printf '   ✓ %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*" >&2; }
run()  { printf '     $ %s\n' "$*"; [ "$DRY" = 1 ] || "$@"; }

pick() { # pick VAR-VALUE FOLDERNAME -> a local folder (explicit, or next to Halcyon), else empty = GitHub
  if [ -n "$1" ]; then printf '%s' "$1"; elif [ -f "$BUNDLE/$2/Cargo.toml" ]; then printf '%s' "$BUNDLE/$2"; fi
}
# managed clone forced to the newest main; echoes the folder
sync_main() { # sync_main NAME LOCAL REPO
  local name="$1" local_dir="$2" repo="$3" d="$SRC/$1"
  if [ -n "$local_dir" ]; then printf '%s' "$local_dir"; return 0; fi
  mkdir -p "$SRC"
  if [ ! -d "$d/.git" ]; then run git clone --quiet "$repo" "$d" >&2 || return 1; fi
  [ "$DRY" = 1 ] || { git -C "$d" fetch --quiet origin main && git -C "$d" checkout --quiet -f -B main FETCH_HEAD >&2 || return 1; }
  printf '%s' "$d"
}
# the same stamp install.sh saves (LUNA: the commit; the other two: the commit + a hash of uncommitted changes), so neither rebuilds the other's work
stamp_of() {
  if git -C "$1" rev-parse HEAD >/dev/null 2>&1; then
    if [ "${2:-}" = full ]; then echo "$(git -C "$1" rev-parse HEAD)-$(git -C "$1" status --porcelain 2>/dev/null | sha256sum | cut -c1-12)"; else git -C "$1" rev-parse HEAD; fi
  else find "$1" -path "$1/target" -prune -o -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1; fi
}

FAILED=0

# ---------------------------------------------------------------- LUNA
if [ "$(choice LUNA)" = yes ]; then
  say "LUNA"
  d="$(sync_main LUNA-AI "$(pick "${LUNA_SRC:-}" LUNA-AI)" https://github.com/X-netrunner/LUNA-AI.git)" || { warn "LUNA: could not fetch main"; d=""; FAILED=1; }
  if [ -n "$d" ] && [ -f "$d/Cargo.toml" ]; then
    now="$(stamp_of "$d")"; st="$STATE/luna-rev"
    if [ "$FORCE" = 0 ] && [ -x "$HOME/.local/bin/luna" ] && [ "$(cat "$st" 2>/dev/null)" = "$now" ]; then ok "LUNA is up to date (${now:0:7})"
    elif ! command -v cargo >/dev/null 2>&1; then warn "LUNA: cargo is missing"; FAILED=1
    else
      [ -n "$(git -C "$d" rev-parse HEAD 2>/dev/null)" ] && [ -z "$(pick "${LUNA_SRC:-}" LUNA-AI)" ] && run git -C "$d" clean -fdxq
      rm -rf "$BUILD/luna"
      if run env CARGO_TARGET_DIR="$BUILD/luna" cargo build --release --locked --manifest-path "$d/Cargo.toml" \
         && run install -Dm755 "$BUILD/luna/release/luna" "$HOME/.local/bin/luna"; then
        [ "$DRY" = 1 ] || { mkdir -p "$STATE"; printf '%s\n' "$now" > "$st"; rm -rf "$BUILD/luna"; }
        for u in luna-daemon luna-wake; do systemctl --user is-active --quiet "$u.service" 2>/dev/null && run systemctl --user restart "$u.service"; done
        ok "LUNA updated to ${now:0:7}"
      else warn "LUNA did not build: the installed version stays"; FAILED=1; fi
    fi
  fi
fi

# ---------------------------------------------------------------- ai-antivirus (pacman package)
if [ "$(choice ANTIVIRUS)" = yes ] || { [ -z "$(choice ANTIVIRUS)" ] && [ "$(choice SYNAPSE)" = yes ]; }; then
  say "ai-antivirus"
  if ! command -v makepkg >/dev/null 2>&1; then warn "ai-antivirus: makepkg is missing (Arch only)"; FAILED=1
  else
    d="$(sync_main ai-antivirus "$(pick "${AV_SRC:-}" ai-antivirus)" https://github.com/X-netrunner/ai-antivirus)" || { warn "ai-antivirus: could not fetch main"; d=""; FAILED=1; }
    if [ -n "$d" ] && [ -f "$d/Cargo.toml" ]; then
      now="$(stamp_of "$d" full)"; st="$STATE/ai-antivirus-src"
      if [ "$FORCE" = 0 ] && pacman -Q ai-antivirus >/dev/null 2>&1 && [ "$(cat "$st" 2>/dev/null)" = "$now" ]; then ok "ai-antivirus is up to date (${now:0:7})"
      else
        # the eBPF object: rebuilt when bpf-linker is there, else the installed one is reused
        if command -v bpf-linker >/dev/null 2>&1; then run bash -c "cd '$d' && cargo xtask build-ebpf --release" || warn "eBPF rebuild failed"
        elif [ ! -f "$d/target/bpf/ai-antivirus-ebpf.o" ] && [ -f /usr/lib/ai-antivirus/ai-antivirus-ebpf.o ]; then
          warn "bpf-linker missing: reusing the installed eBPF object"; run mkdir -p "$d/target/bpf"; run cp /usr/lib/ai-antivirus/ai-antivirus-ebpf.o "$d/target/bpf/ai-antivirus-ebpf.o"
        fi
        run bash -c "find '$d/packaging/arch' -maxdepth 1 -name '*.pkg.tar.*' -delete; rm -rf '$d/packaging/arch/pkg'"
        active=(); for s in engined sensord responderd analyzer; do systemctl is-active --quiet "ai-antivirus-$s.service" 2>/dev/null && active+=("ai-antivirus-$s"); done
        if run bash -c "cd '$d/packaging/arch' && makepkg -f --noconfirm"; then
          pkg="$(ls -t "$d"/packaging/arch/ai-antivirus-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)"
          if [ "$DRY" = 1 ] || { [ -n "$pkg" ] && run sudo pacman -U --noconfirm "$pkg"; }; then
            for s in ${active[@]+"${active[@]}"}; do run sudo systemctl restart "$s.service"; done
            [ "$DRY" = 1 ] || { mkdir -p "$STATE"; printf '%s\n' "$now" > "$st"; }
            ok "ai-antivirus updated to ${now:0:7}"
          else warn "ai-antivirus: install failed, the installed version stays"; FAILED=1; fi
        else warn "ai-antivirus did not build: the installed version stays"; FAILED=1; fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- ai-firewall
if [ "$(choice FIREWALL)" = ai ]; then
  say "ai-firewall"
  if pacman -Q ai-firewall >/dev/null 2>&1 || pacman -Q ai-firewall-git >/dev/null 2>&1; then ok "ai-firewall is a pacman package: pacman keeps it updated"
  else
    d="$(sync_main ai-firewall "$(pick "${AIFW_SRC:-}" ai-firewall)" https://github.com/X-netrunner/ai-firewall.git)" || { warn "ai-firewall: could not fetch main"; d=""; FAILED=1; }
    if [ -n "$d" ] && [ -f "$d/Cargo.toml" ]; then
      now="$(stamp_of "$d" full)"; st="$STATE/aifw-src"
      if [ "$FORCE" = 0 ] && [ -x /usr/local/bin/ai-firewall ] && [ "$(cat "$st" 2>/dev/null)" = "$now" ]; then ok "ai-firewall is up to date (${now:0:7})"
      elif ! command -v rustup >/dev/null 2>&1 || ! command -v bpf-linker >/dev/null 2>&1; then warn "ai-firewall needs rustup (nightly + rust-src) and bpf-linker: the installed version stays"; FAILED=1
      else
        rm -rf "$BUILD/ai-firewall"
        if run env CARGO_TARGET_DIR="$BUILD/ai-firewall" cargo +nightly build --release --locked --manifest-path "$d/Cargo.toml" -p ai-firewall \
           && run sudo install -Dm755 "$BUILD/ai-firewall/release/ai-firewall" /usr/local/bin/ai-firewall \
           && run sudo install -Dm644 "$d/packaging/ai-firewall.service" /etc/systemd/system/ai-firewall.service; then
          run sudo systemctl daemon-reload
          # filtering never stops during a restart (pinned bpf links); a stopped firewall is not started behind your back
          systemctl is-active --quiet ai-firewall.service && run sudo systemctl restart ai-firewall.service
          [ "$DRY" = 1 ] || { mkdir -p "$STATE"; printf '%s\n' "$now" > "$st"; rm -rf "$BUILD/ai-firewall"; }
          ok "ai-firewall updated to ${now:0:7}"
        else warn "ai-firewall did not build: the installed version stays"; FAILED=1; fi
      fi
    fi
  fi
fi

[ "$FAILED" = 0 ]
