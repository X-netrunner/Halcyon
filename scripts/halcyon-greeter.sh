#!/usr/bin/env bash
# halcyon-greeter.sh: Halcyon's own login screen (a greetd greeter, greeter/shell.qml), in the lock screen's look.
#
#   halcyon-greeter.sh install     set it up (asks for sudo once): greetd + cage, the greeter, /etc/greetd/config.toml, greetd enabled
#   halcyon-greeter.sh refresh     copy this Halcyon folder's login-screen files over the installed (root-owned) copy: run it after an update
#   halcyon-greeter.sh sync        copy your colours, wallpaper, picture and the user list for the greeter (no root; a user service does it for you)
#   halcyon-greeter.sh preview     open the login screen as a window in your running desktop, nothing is logged in (password: preview)
#   halcyon-greeter.sh apply [greeter|lock]   what happens at boot: this login screen, or auto-login + the lock screen
#   halcyon-greeter.sh lockmode login|lock    what the lock screen is after sleep: login-screen look (no widgets) or the lock screen with widgets
#   halcyon-greeter.sh doctor     fix "[libseat] could not connect to socket /run/seatd.sock" at login (seatd + pam_systemd)
#   halcyon-greeter.sh status      what is set up
#   halcyon-greeter.sh remove      put your old login manager / tty1 setup back and delete the greeter
#
# What it changes: it enables greetd (the old display manager is only switched off, its name is saved), backs up
# /etc/greetd/config.toml, and removes the tty1 auto-login of the lock-screen login (greetd is the login now).
# Nothing takes effect until the next boot; Ctrl+Alt+F2 stays a normal text login the whole time.
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RICE="${HALCYON_DIR:-$(dirname "$here")}"
[ -f "$RICE/greeter/shell.qml" ] || RICE="$HOME/.config/Halcyon"
SRC="$RICE/greeter"
SHARE=/usr/local/share/halcyon-greeter
VAR=${HALCYON_GREETER_VAR:-/var/lib/halcyon-greeter}
CONF=/etc/greetd/config.toml
MARK="# halcyon-greeter"
GETTY=/etc/systemd/system/getty@tty1.service.d/halcyon-autologin.conf

say()  { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
die() { say "halcyon-greeter: $*" >&2; exit 1; }

OWN="shell.qml users.sh sessions.sh halcyon-session"   # the greeter's own files (halcyon-session is the executable wrapper greetd runs)
ART="Backdrop.qml ModeArt.qml BarStars.qml StarData.js LiveSky.qml"       # the lock screen's own art (constellation, sky): one source of truth, copied from the island
stage() {           # stage DIR: the greeter's files plus the shared art, as plain copies
  local d="$1" f
  for f in $OWN; do cp -f "$SRC/$f" "$d/$f" || return 1; done
  for f in $ART; do cp -f "$RICE/quickshell/island/$f" "$d/$f" || { say "missing $RICE/quickshell/island/$f"; return 1; }; done
}

mode_of() { case "$1" in halcyon-session) echo 755 ;; *) echo 644 ;; esac; }
share_stale() {     # 0 = the installed copy differs from this folder's files (or has a leftover); 1 = current, or not installed
  local d f stale=1
  [ -f "$SHARE/shell.qml" ] || return 1
  d="$(mktemp -d)" && stage "$d" >/dev/null 2>&1 || { rm -rf "$d"; return 1; }
  for f in $OWN $ART; do cmp -s "$d/$f" "$SHARE/$f" || stale=0; done
  [ -e "$SHARE/Geometry.qml" ] && stale=0
  rm -rf "$d"; return $stale
}
share_refresh() {   # copy the files over the root-owned copy (the boot login screen runs THAT copy, not this folder)
  local tmp f
  tmp="$(mktemp -d)" && stage "$tmp" || { say "could not stage the greeter files"; return 1; }
  for f in $OWN $ART; do as_root install -m "$(mode_of "$f")" -o root -g root "$tmp/$f" "$SHARE/$f" || { say "could not copy $f"; rm -rf "$tmp"; return 1; }; done
  as_root rm -f "$SHARE/Geometry.qml"
  rm -rf "$tmp"
}

sync_theme() {      # runs as the user; writes $VAR/theme.json, wallpaper, avatars
  [ -d "$VAR" ] && [ -w "$VAR" ] || { [ "${1:-}" = --quiet ] || say "Nothing to sync: $VAR is missing or not yours (run: halcyon-greeter.sh install)."; return 0; }
  python3 - "$VAR" "$HOME" "$RICE" <<'PY'
import json, os, pwd, re, shutil, glob, subprocess, sys
var, home, rice = sys.argv[1:4]
def rd(p, d=None):
    try:
        with open(p) as f: return f.read()
    except Exception: return d
def reencode(src, dst, size):
    # a picture is decoded by the greeter: when ImageMagick is there, hand it a clean, resized copy instead of the original file
    for tool in ("magick", "convert"):
        if shutil.which(tool):
            try:
                r = subprocess.run([tool, src + "[0]", "-auto-orient", "-resize", "%dx%d>" % (size, size), "-strip", dst], capture_output=True, timeout=60)
                if r.returncode == 0 and os.path.getsize(dst) > 0: return True
            except Exception: pass
    return False
look = {}
try:
    look = json.loads(rd(os.path.join(home, ".cache/island/greeter-look.json"), "{}"))
    if not isinstance(look, dict) or look.get("v") != 1: look = {}
except Exception: look = {}
pal = {}
try: pal = json.loads(rd(os.path.join(home, ".cache/island/palette.json"), "{}"))
except Exception: pass
opt = {}
try: opt = (json.loads(rd(os.path.join(home, ".local/state/island/settings.json"), "{}")) or {}).get("opt", {}) or {}
except Exception: pass
out = {k: pal[k] for k in ("bg", "surface", "accent", "accent2", "text", "muted") if k in pal}
out["look"] = look            # the lock screen's own look (palette, sizes, fonts, constellation); the greeter uses it when it is there
# background: the lock screen's own choice (wallpaper / solid / sky), or forced from Settings
gb = opt.get("greeterBg", "lock")
bgmode = look.get("bgMode", opt.get("lockBg", "solid")) if gb == "lock" else gb
want_wall = bgmode == "wallpaper"
out["bgMode"] = bgmode if bgmode in ("wallpaper", "solid", "sky") else "solid"
# wallpaper: the one on screen (line 2 of ~/.local/state/island/wallpaper); copied so the greeter user can read it
wp = (rd(os.path.join(home, ".local/state/island/wallpaper"), "") or "").split("\n")
wp = wp[1].strip() if len(wp) > 1 else ""
if want_wall and wp and os.path.isfile(wp) and not wp.lower().endswith((".mp4", ".webm", ".mkv", ".gif")):
    ext = os.path.splitext(wp)[1].lower() or ".jpg"
    dst = os.path.join(var, "wallpaper" + ext)
    try:
        for old in glob.glob(os.path.join(var, "wallpaper.*")):
            if old != dst: os.remove(old)
        if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(wp) or os.path.getsize(dst) != os.path.getsize(wp):
            if not reencode(wp, dst, 3840): shutil.copyfile(wp, dst)
            os.chmod(dst, 0o644)
        out["wallpaper"] = dst
    except Exception: pass
elif not want_wall:
    for old in glob.glob(os.path.join(var, "wallpaper.*")):
        try: os.remove(old)
        except Exception: pass
# font: the lock screen's font when it is installed for everyone (the greeter cannot see ~/.local/share/fonts), else the system sans
def system_font(name):
    try:
        r = subprocess.run(["fc-match", "-f", "%{family}|%{file}", name], capture_output=True, text=True, timeout=3).stdout
        fam, _, path = r.partition("|")
        if fam and not path.startswith(home): return fam.split(",")[0]
    except Exception: pass
    return ""
f = system_font(look.get("uiFont", "")) or system_font("sans")
if f: out["font"] = f
# avatars: only yours is copied (the greeter cannot read your home); other people's come from AccountsService when they have one.
# Users and sessions are NOT written here: the greeter reads them from the system itself (a file you can write must not decide who logs in or what runs).
avatars = {}
me = pwd.getpwuid(os.getuid()).pw_name
# the picture set in Halcyon comes first: the one the island shows (greeter-look.json "avatar"), then the one chosen in the
# profile (settings.json "profileAvatar"), then the usual places (same order as scripts/avatar.sh / `hal avatar`)
settings = {}
try: settings = json.loads(rd(os.path.join(home, ".local/state/island/settings.json"), "{}")) or {}
except Exception: settings = {}
def expand(p):
    p = (p or "").strip() if isinstance(p, str) else ""
    return os.path.join(home, p[1:].lstrip("/")) if p.startswith("~") else p
cands = [expand(look.get("avatar")), expand(settings.get("profileAvatar")),
         os.path.join(home, ".face"), os.path.join(home, ".face.icon"), "/var/lib/AccountsService/icons/" + me]
cands += [os.path.join(home, ".config/Halcyon/avatar." + e) for e in ("png", "jpg", "jpeg", "webp")]
cands += [os.path.join(home, "Pictures/avatar." + e) for e in ("png", "jpg", "jpeg", "webp")]
cands += glob.glob(os.path.join(home, ".local/state/island/avatar*")) + glob.glob(os.path.join(home, ".cache/island/avatar*"))
src = ""
for c in cands:
    if c and os.path.isfile(c) and os.path.getsize(c) > 0: src = c; break
if src:
    dst = os.path.join(var, "avatar-" + me + ".img")
    try:
        if not reencode(src, dst, 256): shutil.copyfile(src, dst)
        os.chmod(dst, 0o644); avatars[me] = dst
    except Exception: pass
else:
    try: os.remove(os.path.join(var, "avatar-" + me + ".img"))
    except Exception: pass
for p in pwd.getpwall():
    if p.pw_uid >= 1000 and p.pw_name != me and os.path.isfile("/var/lib/AccountsService/icons/" + p.pw_name):
        avatars[p.pw_name] = "/var/lib/AccountsService/icons/" + p.pw_name
out["avatars"] = avatars
out["blur"] = look.get("blur", opt.get("lockBlur", 40)) if gb == "lock" else opt.get("lockBlur", 40)
out["tint"] = look.get("tint", opt.get("lockTint", 0.55)) if gb == "lock" else opt.get("lockTint", 0.55)
# the options (Settings > Login screen)
# the constellation is ONE switch for the lock screen and the login screen (Settings > Lock screen)
out["stars"] = opt.get("starsLock", True) is not False
out["clock"] = opt.get("greeterClock", True) is not False
out["avatar"] = opt.get("greeterAvatar", True) is not False
out["seconds"] = opt.get("greeterSeconds", False) is True
out["power"] = opt.get("greeterPower", True) is not False
out["session"] = opt.get("greeterSession", True) is not False
out["battery"] = opt.get("greeterBattery", False) is True
out["wifi"] = opt.get("greeterWifi", False) is True
tmp = os.path.join(var, "theme.json.tmp")
with open(tmp, "w") as f: json.dump(out, f)
os.chmod(tmp, 0o644); os.replace(tmp, os.path.join(var, "theme.json"))
PY
  [ "${1:-}" = --quiet ] || say "Greeter theme synced."
}

# --- the session needs a seat: libseat asks seatd, then logind. "[libseat] could not connect to socket /run/seatd.sock" at login means
# neither answered: the PAM stack greetd uses has no pam_systemd (no logind session), and seatd was not running. Fix both.
pam_has_systemd() {   # does /etc/pam.d/$1 (or anything it includes) load pam_systemd?
  local f="/etc/pam.d/$1" line inc
  [ -r "$f" ] || return 1
  case " ${2:-} " in *" $1 "*) return 1 ;; esac
  grep -Eq '^[^#]*pam_systemd\.so' "$f" && return 0
  while read -r line; do
    inc="$(printf '%s\n' "$line" | awk '$1 !~ /^#/ && ($2 == "include" || $2 == "substack") { print $3 }')"
    [ -n "$inc" ] && pam_has_systemd "$inc" "${2:-} $1" && return 0
  done < "$f"
  return 1
}
seat_fix() {
  local me; me="${OWNER:-$(id -un)}"
  say "Checking the seat (logind / seatd) for the session..."
  if ! pam_has_systemd greetd; then
    say "  greetd's PAM stack has no pam_systemd: adding it (a backup is /etc/pam.d/greetd.halcyon-bak)"
    [ -e /etc/pam.d/greetd.halcyon-bak ] || { [ -f /etc/pam.d/greetd ] && as_root cp -a /etc/pam.d/greetd /etc/pam.d/greetd.halcyon-bak; }
    if [ -f /etc/pam.d/greetd ]; then printf '%s\n' "-session   optional   pam_systemd.so" | as_root tee -a /etc/pam.d/greetd >/dev/null
    else say "  /etc/pam.d/greetd does not exist: greetd cannot log anyone in without it"; fi
  else say "  PAM: pam_systemd is loaded for greetd sessions."; fi
  if ! have seatd; then
    if have pacman; then as_root pacman -S --needed --noconfirm seatd >/dev/null 2>&1 || say "  could not install seatd"
    elif have dnf; then as_root dnf install -y seatd >/dev/null 2>&1 || say "  could not install seatd"
    else say "  install the seatd package yourself (a fallback seat service)"; fi
  fi
  if have seatd; then
    as_root systemctl enable --now seatd.service >/dev/null 2>&1 || say "  could not start seatd.service"
    if getent group seat >/dev/null; then
      as_root usermod -aG seat "$me" 2>/dev/null && say "  you ($me) are in the 'seat' group (takes effect at your next login)"
      getent passwd greeter >/dev/null && as_root usermod -aG seat greeter 2>/dev/null
    else say "  no 'seat' group: libseat uses seatd only if your user may open /run/seatd.sock"; fi
    [ -S /run/seatd.sock ] && say "  seatd is running (/run/seatd.sock)." || say "  seatd is not running yet."
  fi
}

user_units() {      # a user service that re-syncs whenever the wallpaper palette changes
  local d="$HOME/.config/systemd/user"; mkdir -p "$d"
  cat > "$d/halcyon-greeter-sync.service" <<UNIT
[Unit]
Description=Copy Halcyon's colours and wallpaper to the login screen
[Service]
Type=oneshot
ExecStart=$RICE/scripts/halcyon-greeter.sh sync --quiet
UNIT
  cat > "$d/halcyon-greeter-sync.path" <<UNIT
[Unit]
Description=Watch Halcyon's palette for the login screen
[Path]
PathChanged=%h/.cache/island/palette.json
PathChanged=%h/.local/state/island/settings.json
PathChanged=%h/.cache/island/greeter-look.json
Unit=halcyon-greeter-sync.service
[Install]
WantedBy=default.target
UNIT
  if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload; systemctl --user enable --now halcyon-greeter-sync.path >/dev/null 2>&1 || true
  fi
}

case "${1:-}" in
  install)
    # normally run as your own user (it asks for sudo). install.sh started with sudo / as root passes the owner instead:
    #   HALCYON_GREETER_OWNER=<you> halcyon-greeter.sh install
    if [ "$(id -u)" -eq 0 ]; then
      OWNER="${HALCYON_GREETER_OWNER:-${SUDO_USER:-}}"
      { [ -n "$OWNER" ] && [ "$OWNER" != root ] && getent passwd "$OWNER" >/dev/null; } \
        || die "run this as your own user (it asks for sudo), or as root with HALCYON_GREETER_OWNER=<your user>."
    else OWNER="$(id -un)"; fi
    have systemctl || die "this needs systemd."
    [ -f "$SRC/shell.qml" ] || die "greeter/shell.qml not found in $RICE."
    have quickshell || die "quickshell is not installed."
    miss=""; have greetd || miss="$miss greetd"; have cage || miss="$miss cage"; have seatd || miss="$miss seatd"
    if [ -n "$miss" ]; then
      if have pacman; then say "Installing:$miss"; as_root pacman -S --needed --noconfirm $miss || die "pacman could not install:$miss"
      elif have dnf; then say "Installing:$miss"; as_root dnf install -y $miss || die "dnf could not install:$miss (greetd needs Fedora 40+ / a copr)"
      else die "install these first:$miss (greetd and cage)"; fi
    fi
    [ -f /etc/pam.d/greetd ] || say "Warning: /etc/pam.d/greetd is missing; greetd may refuse logins until it exists."
    if ! getent passwd greeter >/dev/null; then
      as_root useradd -M -r -s /usr/bin/nologin -G video greeter 2>/dev/null || say "Warning: could not create the 'greeter' user (greetd's package normally makes it)."
    fi
    # the greeter, the data folder (yours: sync needs no root) and the greeter's own state folder
    as_root install -d -m 755 "$SHARE"
    tmp="$(mktemp -d)" && stage "$tmp" || die "could not stage the greeter files"
    for f in $OWN $ART; do as_root install -m "$(mode_of "$f")" -o root -g root "$tmp/$f" "$SHARE/$f" || die "could not copy $f"; done
    rm -rf "$tmp"
    as_root install -d -m 755 -o "$OWNER" "$VAR"
    as_root install -d -m 755 -o greeter "$VAR/state"
    as_root install -d -m 700 -o greeter "$VAR/state/cache" "$VAR/state/qs" "$VAR/state/data"
    # the old display manager: remembered, then replaced
    prev="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null)"
    case "$prev" in greetd|display-manager|"") ;; *) [ -s "$VAR/previous-dm" ] || printf '%s\n' "$prev" | as_root tee "$VAR/previous-dm" >/dev/null ;; esac
    # greetd's config
    as_root install -d -m 755 /etc/greetd
    if [ -f "$CONF" ] && ! grep -q "$MARK" "$CONF" && [ ! -e "$CONF.halcyon-bak" ]; then as_root cp -a "$CONF" "$CONF.halcyon-bak"; fi
    as_root tee "$CONF" >/dev/null <<CFG
$MARK (written by Halcyon's scripts/halcyon-greeter.sh; halcyon-greeter.sh remove puts the old file back)
[terminal]
vt = 1

[default_session]
# cage is a tiny single-window compositor; the greeter is a Quickshell window inside it. Ctrl+Alt+F2 stays a text login.
# the greeter user often has no home folder: Quickshell's cache / state go to the greeter's own folder instead
command = "env XDG_CACHE_HOME=$VAR/state/cache XDG_STATE_HOME=$VAR/state/qs XDG_DATA_HOME=$VAR/state/data cage -s -d -m last -- quickshell -p $SHARE"
user = "greeter"
CFG
    # greetd replaces the old display manager; the tty1 auto-login of the lock-screen login is not needed any more
    as_root systemctl enable --force greetd.service >/dev/null 2>&1 || die "could not enable greetd.service"
    if [ -f "$GETTY" ]; then as_root rm -f "$GETTY"; as_root rmdir "$(dirname "$GETTY")" 2>/dev/null; as_root systemctl daemon-reload; say "Removed the tty1 auto-login (greetd logs you in now)."; fi
    seat_fix
    if [ "$(id -u)" -eq 0 ]; then
      # the rest belongs to the owner: their tty1 auto-login line, the sync service and the first copy of their look
      ouid="$(id -u "$OWNER")"; ohome="$(getent passwd "$OWNER" | cut -d: -f6)"
      runuser -u "$OWNER" -- env HOME="$ohome" USER="$OWNER" XDG_RUNTIME_DIR="/run/user/$ouid" HALCYON_DIR="$RICE" bash "$0" user-finish \
        || say "Could not finish as $OWNER: run  $0 sync  as $OWNER once."
    else
      bash "$0" user-finish
    fi
    say ""
    say "Done. greetd and the Halcyon login screen start at the next boot."
    say "  try it now, safely:   $0 preview        (password: preview)"
    say "  if something breaks:  Ctrl+Alt+F2 -> log in -> $0 remove"
    ;;
  refresh)       # after an update: the boot login screen runs the root-owned copy in $SHARE, so it keeps the old files until this runs
    [ -f "$SHARE/shell.qml" ] || { say "The Halcyon login screen is not installed here: nothing to refresh."; exit 0; }
    if share_stale; then
      share_refresh || die "the login screen files were not updated."
      say "Login screen files updated in $SHARE (they are used at the next boot or login-screen start)."
    else say "The installed login screen already matches this folder."; fi ;;
  doctor)        # re-check the seat and PAM (the \"[libseat] could not connect to socket /run/seatd.sock\" login failure) and repair them
    [ "$(id -u)" -ne 0 ] || die "run this as your own user (it asks for sudo)."
    seat_fix
    # greetd and the tty1 auto-login of the lock-screen login both want tty1: with both set, the session opens and dies at once
    if grep -q "$MARK" "$CONF" 2>/dev/null; then
      if [ -f "$GETTY" ]; then
        say "tty1 auto-login was still set next to greetd (they fight over tty1, and the session dies): removing the auto-login."
        as_root rm -f "$GETTY"; as_root rmdir "$(dirname "$GETTY")" 2>/dev/null; as_root systemctl daemon-reload
      fi
      [ -x "$here/user-setup.sh" ] && "$here/user-setup.sh" login-remove >/dev/null 2>&1
      rm -f "$HOME/.cache/island/lock-on-start"
    fi
    say ""
    say "Login screen checks:"
    for b in greetd cage quickshell; do have "$b" && say "  $b: installed" || say "  $b: MISSING (the login screen cannot start without it)"; done
    getent passwd greeter >/dev/null && say "  greeter user: present" || say "  greeter user: MISSING (greetd runs the login screen as this user)"
    grep -q "$MARK" "$CONF" 2>/dev/null && say "  /etc/greetd/config.toml: Halcyon's" || say "  /etc/greetd/config.toml: NOT Halcyon's (run: $0 install)"
    systemctl is-enabled greetd.service >/dev/null 2>&1 && say "  greetd.service: enabled" || say "  greetd.service: NOT enabled (run: $0 install)"
    [ "$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null)" = greetd ] \
      && say "  display-manager.service: greetd" || say "  display-manager.service: not greetd (another login manager will start at boot)"
    if [ ! -f "$SHARE/shell.qml" ]; then say "  login screen files: MISSING in $SHARE (run: $0 install)"
    elif share_stale; then say "  login screen files: OUT OF DATE (an older copy was installed): updating them now"; share_refresh && say "  updated."
    else say "  login screen files: current"; fi
    [ -s "$VAR/theme.json" ] && say "  theme: synced $(date -r "$VAR/theme.json" '+%F %T')" || say "  theme: never synced (run: $0 sync)"
    [ -x /usr/local/bin/start-halcyon ] && say "  start-halcyon: present" || say "  start-halcyon: MISSING (the Halcyon session has nothing to start: run ./install.sh)"
    [ -f /usr/share/wayland-sessions/halcyon.desktop ] && say "  Halcyon session file: present" || say "  Halcyon session file: MISSING (run ./install.sh)"
    [ -x "$SHARE/halcyon-session" ] && say "  halcyon-session wrapper: present" || say "  halcyon-session wrapper: MISSING or not executable in $SHARE (run: $0 refresh): every login would end at once"
    if grep -E 'Greetd\.launch' "$SRC/shell.qml" 2>/dev/null | grep -q -- '"-c"'; then
      say "  greeter: Greetd.launch passes a shell script as ONE argument (greetd splits it at spaces and the session dies at once): update Halcyon"
    fi
    say ""
    say "What greetd printed during this boot (the login screen's own errors are here):"
    as_root journalctl -b -u greetd.service --no-pager -n 30 2>/dev/null | sed 's/^/  | /' || true
    say ""
    say "What the last login-screen session wrote (~/.cache/island/launch.log, keyboard-compiler noise left out):"
    lg="$HOME/.cache/island/launch.log"
    if [ -s "$lg" ]; then
      ln="$(grep -n "started by the login manager" "$lg" | tail -n1 | cut -d: -f1)"
      if [ -n "$ln" ]; then
        say "  (from the last login-manager start, line $ln of the log)"
        tail -n +"$((ln > 1 ? ln - 1 : 1))" "$lg" | grep -v -E "xkbcomp|^> |Using 0, ignoring|Using last definition|got an event from hyprland" | head -n 80 | sed 's/^/  | /'
      else
        say "  (no login-manager start is recorded: the session never reached launch/halcyon.sh, or the log is from a tty start; its last lines:)"
        grep -v -E "xkbcomp|^> |Using 0, ignoring|Using last definition|got an event from hyprland" "$lg" | tail -n 20 | sed 's/^/  | /'
      fi
      say "  log last written: $(date -r "$lg" '+%F %T')"
    else say "  (empty: the session never reached launch/halcyon.sh)"; fi
    say "How the last session started from the login screen ended (~/.cache/island/greeter-session.log; written by the login screen's session wrapper):"
    gs="$HOME/.cache/island/greeter-session.log"
    if [ -s "$gs" ]; then tail -n 14 "$gs" | sed 's/^/  | /'; say "  log last written: $(date -r "$gs" '+%F %T')"
    else say "  (nothing yet: either no login was tried since this was installed, or the session died BEFORE its first line, i.e. while greetd sourced /etc/profile or ~/.profile, or in PAM)"; fi
    say "Hyprland crash reports: $(ls -t "$HOME"/.cache/hyprland/hyprlandCrashReport*.txt 2>/dev/null | head -n3 | tr '\n' ' ')"
    say ""
    say "logind session type of your last login: $(loginctl show-session "$XDG_SESSION_ID" -p Type -p Active -p Remote 2>/dev/null | tr '\n' ' ')"
    say "Reboot (or log out and in) once, then try the login screen again." ;;
  lockmode)      # lockmode login|lock: what the lock screen / wake-from-sleep looks like (Settings > Power & lock). No root needed.
    case "${2:-}" in login|lock) ;; *) die "lockmode login|lock" ;; esac
    python3 - "$2" <<'PY2'
import json, os, sys
f = os.path.expanduser("~/.local/state/island/settings.json")
try: d = json.load(open(f))
except Exception: d = {}
d.setdefault("opt", {})["lockMode"] = sys.argv[1]
os.makedirs(os.path.dirname(f), exist_ok=True)
open(f, "w").write(json.dumps(d) + "\n")
PY2
    quickshell ipc -p "$RICE/quickshell/island" call island reloadSettings >/dev/null 2>&1 || true
    say "Lock screen style: $2 (the running island picks it up after a reload: Settings > Reload, or log in again)." ;;
  apply)         # apply login|greeter: what happens at boot. Reads the choice from the island's settings (opt.loginMode) unless given.
    mode="${2:-}"
    [ -n "$mode" ] || mode="$(python3 -c "import json,os;print((json.load(open(os.path.expanduser('~/.local/state/island/settings.json'))).get('opt') or {}).get('loginMode','keep'))" 2>/dev/null)"
    case "$mode" in
      greeter) exec "$0" install ;;
      lock)
        [ "$(id -u)" -ne 0 ] || die "run this as your own user."
        [ -f "$SHARE/shell.qml" ] && "$0" remove
        [ -x "$here/user-setup.sh" ] || die "user-setup.sh not found."
        "$here/user-setup.sh" login-add || die "your login shell is not bash, zsh or fish, so auto-login was NOT set up."
        as_root install -d -m 755 "$(dirname "$GETTY")"
        sed "s|@USER@|$(id -un)|g" <<'GETTYEOF' | as_root tee "$GETTY" >/dev/null
# Written by Halcyon: tty1 logs @USER@ in by itself; the profile then starts Halcyon with the lock screen on (launch/halcyon-login.sh).
# Remove with ./install.sh --remove-lock-login
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --noissue --nohints --skip-login --nonewline --autologin @USER@ - $TERM
TTYReset=no
TTYVTDisallocate=no
GETTYEOF
        as_root systemctl daemon-reload
        say "Auto-login + lock screen is set for the next boot." ;;
      keep|"") say "Nothing to apply (the choice is 'keep')." ;;
      *) die "apply greeter|lock" ;;
    esac ;;
  sync) sync_theme "${2:-}" ;;
  user-finish)   # (used by install) the per-user part, run as the owner
    [ -x "$here/user-setup.sh" ] && "$here/user-setup.sh" login-remove >/dev/null 2>&1
    rm -f "$HOME/.cache/island/lock-on-start"
    user_units
    sync_theme ;;
  preview)
    have quickshell || die "quickshell is not installed."
    sync_theme --quiet
    d="$(mktemp -d)" && stage "$d" || die "could not stage the greeter files"
    say "Preview: type  preview  and press Enter to close it."
    HALCYON_GREETER_PREVIEW=1 HALCYON_GREETER_DIR="$VAR" quickshell -p "$d"; rm -rf "$d" ;;
  status)
    say "greetd:         $(have greetd && echo installed || echo missing)    cage: $(have cage && echo installed || echo missing)"
    say "greeter files:  $([ -f "$SHARE/shell.qml" ] && echo "$SHARE" || echo missing)"
    if [ -f "$SHARE/shell.qml" ]; then if share_stale; then say "installed copy: OUT OF DATE (run: $0 refresh)"; else say "installed copy: current"; fi; fi
    say "config:         $(grep -q "$MARK" "$CONF" 2>/dev/null && echo "Halcyon's" || echo "not Halcyon's")"
    say "enabled:        $(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null)"
    say "previous DM:    $(cat "$VAR/previous-dm" 2>/dev/null || echo none)"
    say "lockout:        $(grep -qs pam_faillock /etc/pam.d/system-auth /etc/pam.d/system-login /etc/pam.d/greetd 2>/dev/null && echo "pam_faillock active (locks after repeated misses)" || echo "no pam_faillock found (only the greeter's own slow-down applies)")"
    say "theme synced:   $([ -s "$VAR/theme.json" ] && date -r "$VAR/theme.json" '+%F %T' || echo never)" ;;
  remove)
    [ "$(id -u)" -ne 0 ] || die "run this as your own user (it asks for sudo), not as root."
    prev="$(cat "$VAR/previous-dm" 2>/dev/null)"
    if grep -q "$MARK" "$CONF" 2>/dev/null; then
      if [ -e "$CONF.halcyon-bak" ]; then as_root mv -f "$CONF.halcyon-bak" "$CONF"; else as_root rm -f "$CONF"; fi
    fi
    as_root systemctl disable greetd.service >/dev/null 2>&1
    if [ -n "$prev" ] && [ -e "/usr/lib/systemd/system/$prev.service" -o -e "/etc/systemd/system/$prev.service" ]; then
      as_root systemctl enable --force "$prev.service" >/dev/null 2>&1 && say "Your old login manager ($prev) is enabled again."
    else say "No earlier login manager: you get a text console. Start Halcyon with start-halcyon, or run ./install.sh --lock-login."; fi
    systemctl --user disable --now halcyon-greeter-sync.path >/dev/null 2>&1
    rm -f "$HOME/.config/systemd/user/halcyon-greeter-sync."{service,path}; systemctl --user daemon-reload 2>/dev/null
    as_root rm -rf "$SHARE" "$VAR"
    say "Removed. (greetd and cage packages are left installed.) Takes effect at the next boot." ;;
  -h|--help|"") sed -n 2,17p "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command $1 (install | refresh | apply | lockmode | doctor | sync | preview | status | remove)" ;;
esac
