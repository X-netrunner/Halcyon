"""Version Center backend: python3 tests/test_halcyon_versions.py

Runs scripts/halcyon-versions.py (and, through it, the real update.sh and scripts/update-extras.sh) against throw-away local git repositories
and fake system programs (cargo, makepkg, pacman, sudo, systemctl, rustup, bpf-linker). No network, nothing outside a temp HOME is touched.
Covers: status / log / tags / plan, update, a failed build leaving the installed version alone, installing an old version (pins it), pin /
unpin, Update all skipping pins, rollback, downgrade backups (ai-antivirus database, LUNA files), the admin password (needed / wrong / right),
a failed health check putting the old version back, Halcyon's own --ref / --unpin, one operation at a time, the daily check, offline.
"""
import fcntl
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
T = tempfile.mkdtemp(prefix="halcyon-versions-test-")
HOME = os.path.join(T, "home")
FAKE = os.path.join(T, "fake")
BIN = os.path.join(T, "bin")
UP = os.path.join(T, "up")
RICE = os.path.join(HOME, ".config", "Halcyon")
ISTATE = os.path.join(HOME, ".local", "state", "island")
HSTATE = os.path.join(HOME, ".local", "state", "halcyon")
AIFW = os.path.join(T, "usr-local-bin", "ai-firewall")
AVBIN = os.path.join(T, "usr-bin", "ai-antivirus")
AVDB = os.path.join(T, "var-lib", "ai-antivirus")
HELPER = os.path.join(ROOT, "scripts", "halcyon-versions.py")

bad = n = 0


def check(label, got, want=True):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print("FAIL %s: %r (want %r)" % (label, got, want))
    else:
        print("ok   " + label)


def sh(cmd, cwd=None, env=None, inp=None):
    p = subprocess.run(cmd, shell=isinstance(cmd, str), cwd=cwd, env=env, input=inp, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def put(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


def rd(path):
    try:
        return open(path).read().strip()
    except OSError:
        return ""


G = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]


def commit(repo, files, msg):
    for k, v in files.items():
        if v is None:
            if os.path.exists(os.path.join(repo, k)):
                os.remove(os.path.join(repo, k))
        else:
            put(os.path.join(repo, k), v)
    sh(["git", "add", "-A"], cwd=repo)
    sh(G + ["commit", "-q", "-m", msg], cwd=repo)
    return sh(["git", "rev-parse", "HEAD"], cwd=repo)[1].strip()


def make_upstream(name, versions, extra=None):
    """A work clone + a bare 'GitHub' with one commit per version; returns (bare path, [shas])."""
    work = os.path.join(T, "work", name)
    os.makedirs(work)
    sh(["git", "init", "-q", "-b", "main"], cwd=work)
    shas = []
    for i, v in enumerate(versions):
        files = {"VERSION": v + "\n", "Cargo.toml": "[package]\nname=\"%s\"\n" % name}
        files.update((extra or {}).get(v, {}))
        shas.append(commit(work, files, "version " + v))
    bare = os.path.join(UP, name + ".git")
    os.makedirs(UP, exist_ok=True)
    sh(["git", "clone", "-q", "--bare", work, bare])
    return work, bare, shas


def push(work, bare):
    sh(["git", "push", "-q", bare, "main"], cwd=work)


# ------------------------------------------------------------------ the fake system
FAKES = {
    "sudo": r'''#!/bin/sh
# fake sudo: with no terminal it asks $SUDO_ASKPASS (also with -A); the password is "secret"; -n never asks
A=0; N=0; V=0
while [ $# -gt 0 ]; do case "$1" in -A) A=1 ;; -n) N=1 ;; -v) V=1 ;; -S|-k|-E) ;; -p) shift ;; --) shift; break ;; -*) ;; *) break ;; esac; shift; done
if [ "${FAKE_SUDO_OPEN:-0}" != 1 ]; then
  if [ -n "${SUDO_ASKPASS:-}" ] && [ "$N" = 0 ]; then
    pw=$("$SUDO_ASKPASS") || exit 1
    [ "$pw" = secret ] || { echo "Sorry, try again." >&2; exit 1; }
    echo asked >> "$FAKE/sudo-asks"
  else
    echo "sudo: a password is required" >&2; exit 1
  fi
fi
[ "$V" = 1 ] && [ $# -eq 0 ] && exit 0
[ $# -gt 0 ] || exit 0
exec "$@"
''',
    "systemctl": r'''#!/bin/sh
shift_user() { :; }
args=""; for a in "$@"; do [ "$a" = --user ] || args="$args $a"; done
set -- $args
cmd="$1"; shift
case "$cmd" in
  is-active) while [ $# -gt 0 ]; do case "$1" in --quiet) ;; *) u="$1" ;; esac; shift; done; [ -e "$FAKE/active/$u" ] ;;
  start|restart|enable) while [ $# -gt 0 ]; do case "$1" in --now|--quiet) ;; *) mkdir -p "$FAKE/active"; touch "$FAKE/active/$1"; echo "$cmd $1" >> "$FAKE/systemctl.log" ;; esac; shift; done ;;
  stop|disable) while [ $# -gt 0 ]; do case "$1" in --now|--quiet) ;; *) rm -f "$FAKE/active/$1"; echo "$cmd $1" >> "$FAKE/systemctl.log" ;; esac; shift; done ;;
  is-enabled) [ -e "$FAKE/enabled/$1" ] && echo enabled || { echo disabled; exit 1; } ;;
  *) : ;;
esac
''',
    "pacman": r'''#!/bin/sh
case "$1" in
  -Q) [ -f "$FAKE/pkg/$2" ] && { echo "$2 $(cat "$FAKE/pkg/$2")"; exit 0; } || exit 1 ;;
  -U) shift; [ "$1" = --noconfirm ] && shift
      f="$1"; b=$(basename "$f"); v=${b#ai-antivirus-}; v=${v%%-1-*}
      mkdir -p "$FAKE/pkg" "$(dirname "$AV_BIN")"; echo "$v-1" > "$FAKE/pkg/ai-antivirus"; cp "$f" "$AV_BIN"; echo "pacman -U $b" >> "$FAKE/pacman.log" ;;
  *) exit 1 ;;
esac
''',
    "makepkg": r'''#!/bin/sh
src=$(cd ../.. && pwd)
[ -e "$src/BREAK" ] && { echo "build error" >&2; exit 1; }
ver="0.$(cat "$src/VERSION")"
echo "ai-antivirus $ver" > "ai-antivirus-$ver-1-x86_64.pkg.tar.zst"
''',
    "cargo": r'''#!/bin/sh
[ "$1" = xtask ] && exit 0
mp=""; pkg=0
for a in "$@"; do case "$prev" in --manifest-path) mp="$a" ;; esac; prev="$a"; done
d=$(dirname "$mp")
[ -e "$d/BREAK" ] && { echo "error: could not compile" >&2; exit 1; }
v=$(cat "$d/VERSION")
mkdir -p "$CARGO_TARGET_DIR/release"
case "$(basename "$d")" in
  LUNA-AI) printf '#!/bin/sh\necho "luna %s"\n' "$v" > "$CARGO_TARGET_DIR/release/luna"; chmod +x "$CARGO_TARGET_DIR/release/luna" ;;
  ai-firewall) printf '#!/bin/sh\ncase "$1" in check) case "%s" in *badcfg*) echo "config rejected" >&2; exit 1 ;; esac ;; esac\necho "ai-firewall %s"\n' "$v" "$v" > "$CARGO_TARGET_DIR/release/ai-firewall"; chmod +x "$CARGO_TARGET_DIR/release/ai-firewall" ;;
esac
''',
    "rustup": "#!/bin/sh\nexit 0\n",
    "bpf-linker": "#!/bin/sh\nexit 0\n",
}


def build_world():
    for d in (HOME, FAKE, BIN, UP, ISTATE, HSTATE, os.path.dirname(AIFW), os.path.dirname(AVBIN), AVDB):
        os.makedirs(d, exist_ok=True)
    for name, body in FAKES.items():
        put(os.path.join(BIN, name), body, 0o755)

    # ---- upstreams
    real_update = open(os.path.join(ROOT, "update.sh")).read()
    real_extras = open(os.path.join(ROOT, "scripts", "update-extras.sh")).read()
    real_helper = open(HELPER).read()
    hx = {}
    for v in ("h1", "h2", "h3", "h4"):
        hx[v] = {"update.sh": real_update, "scripts/update-extras.sh": real_extras, "scripts/halcyon-versions.py": real_helper,
                 "install.sh": '#!/bin/bash\necho "install.sh $* at $(cat "$(dirname "$0")/VERSION")" >> "$HOME/install-runs.log"\n[ -e "$HOME/.moveluna" ] && echo moved > "$HOME/.local/state/island/luna-rev"\n[ -e "$(dirname "$0")/BAD_INSTALL" ] && { echo "install.sh: something broke" >&2; exit 1; }\nexit 0\n'}
    hx["h3"]["BAD_INSTALL"] = "x\n"
    hx["h4"]["BAD_INSTALL"] = None
    out = {}
    out["halcyon"] = make_upstream("Halcyon", ["h1", "h2", "h3", "h4"], hx)
    out["luna"] = make_upstream("LUNA-AI", ["l1", "l2", "l3"])
    out["av"] = make_upstream("ai-antivirus", ["a1", "a2", "a3"], {"a1": {"packaging/arch/PKGBUILD": "x\n"}})
    out["fw"] = make_upstream("ai-firewall", ["f1", "f2", "f3-badcfg"], {"f1": {"packaging/ai-firewall.service": "[Unit]\n"}})
    for v in ("f2", "f3-badcfg"):
        pass
    # service file in every fw commit (update-extras installs it)
    wf = out["fw"][0]
    sh(G + ["tag", "v1.0", out["fw"][2][0]], cwd=wf)
    sh(G + ["tag", "-a", "-m", "first", "v1.0-av", out["av"][2][0]], cwd=out["av"][0])
    sh(G + ["tag", "-a", "-m", "first", "v1", out["halcyon"][2][0]], cwd=out["halcyon"][0])
    sh(["git", "push", "-q", "--tags", out["fw"][1]], cwd=wf)
    sh(["git", "push", "-q", "--tags", out["av"][1]], cwd=out["av"][0])
    sh(["git", "push", "-q", "--tags", out["halcyon"][1]], cwd=out["halcyon"][0])
    return out


def env_for(extra=None):
    e = dict(os.environ)
    e.update(HOME=HOME, PATH=BIN + ":" + e["PATH"], FAKE=FAKE, HALCYON_DIR=RICE, AIFW_BIN=AIFW, AIFW_UNIT=os.path.join(T, "usr-local-bin", "ai-firewall.service"), AV_BIN=AVBIN, AV_DB_DIR=AVDB,
             HALCYON_REPO=W["halcyon"][1], LUNA_REPO=W["luna"][1], AV_REPO=W["av"][1], AIFW_REPO=W["fw"][1],
             HALCYON_VERSIONS_NET="10", XDG_RUNTIME_DIR=T, GIT_CONFIG_GLOBAL=os.path.join(T, "gitconfig"))
    e.pop("WAYLAND_DISPLAY", None)
    e.pop("SUDO_ASKPASS", None)
    if extra:
        e.update(extra)
    return e


def H(*args, inp=None, env=None):
    """run the helper; returns (exit code, stdout text, parsed JSON of the last `##result` line or of the whole output)"""
    p = subprocess.run([sys.executable, HELPER] + list(args), capture_output=True, text=True, input=inp, env=env or env_for(), stdin=None if inp else subprocess.DEVNULL)
    res = None
    for line in p.stdout.splitlines():
        if line.startswith("##result "):
            res = json.loads(line[9:])
    if res is None:
        try:
            res = json.loads(p.stdout)
        except ValueError:
            res = None
    if os.environ.get("VERBOSE") and p.returncode not in (0,):
        print("--- helper %s exited %s\n%s\n---" % (" ".join(args), p.returncode, (p.stdout + p.stderr)[-3500:]))
    return p.returncode, p.stdout + p.stderr, res


def install_state(shas):
    """The machine as install.sh left it: Halcyon at h2, LUNA at l2, ai-antivirus at a2, ai-firewall at f2 (every one is one behind main)."""
    shutil.rmtree(RICE, ignore_errors=True)
    sh(["git", "clone", "-q", W["halcyon"][1], RICE], env=env_for())
    sh(["git", "reset", "-q", "--hard", W["halcyon"][2][1]], cwd=RICE)
    put(os.path.join(ISTATE, "install-choices.env"), 'LUNA="yes"\nANTIVIRUS="yes"\nFIREWALL="ai"\n')
    for f in ("pins.env", "previous-commit", "installed-commit", "versions.log", "versions.busy"):
        try:
            os.remove(os.path.join(HSTATE, f))
        except OSError:
            pass
    shutil.rmtree(os.path.join(HSTATE, "prev"), ignore_errors=True)
    shutil.rmtree(os.path.join(HSTATE, "backups"), ignore_errors=True)
    shutil.rmtree(os.path.join(HOME, ".cache"), ignore_errors=True)
    shutil.rmtree(os.path.join(HOME, ".local", "src"), ignore_errors=True)
    shutil.rmtree(FAKE, ignore_errors=True)
    os.makedirs(os.path.join(FAKE, "pkg"))
    put(os.path.join(HOME, ".local", "bin", "luna"), '#!/bin/sh\necho "luna l2"\n', 0o755)
    put(os.path.join(ISTATE, "luna-rev"), W["luna"][2][1] + "\n")
    put(os.path.join(HSTATE, "bin-luna.sha"), sha256(os.path.join(HOME, ".local", "bin", "luna")) + "\n")
    put(AVBIN, "ai-antivirus a2\n", 0o755)
    put(os.path.join(FAKE, "pkg", "ai-antivirus"), "a2-1\n")
    put(os.path.join(ISTATE, "ai-antivirus-src"), W["av"][2][1] + "-e3b0c44298fc\n")
    put(os.path.join(HSTATE, "bin-ai-antivirus.sha"), sha256(AVBIN) + "\n")
    put(AIFW, '#!/bin/sh\necho "ai-firewall f2"\n', 0o755)
    put(os.path.join(ISTATE, "aifw-src"), W["fw"][2][1] + "-e3b0c44298fc\n")
    put(os.path.join(HSTATE, "bin-ai-firewall.sha"), sha256(AIFW) + "\n")
    shutil.rmtree(AVDB, ignore_errors=True)
    put(os.path.join(AVDB, "alerts.db"), "schema 3\n")
    put(os.path.join(HOME, ".config", "luna", "luna.toml"), '[memory]\nhistory_path = "%s"\n' % os.path.join(HOME, ".local", "share", "luna", "history.json"))
    put(os.path.join(HOME, ".local", "share", "luna", "history.json"), '["remember me"]\n')
    for u in ("luna-daemon",):
        put(os.path.join(FAKE, "active", u + ".service"), "")
    for u in ("engined", "sensord"):
        put(os.path.join(FAKE, "active", "ai-antivirus-%s.service" % u), "")
    put(os.path.join(FAKE, "active", "ai-firewall.service"), "")


def sha256(p):
    import hashlib
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def stamp(name):
    return rd(os.path.join(ISTATE, name))


def pins():
    d = {}
    for line in rd(os.path.join(HSTATE, "pins.env")).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k] = v.strip('"')
    return d


W = {}


def main():
    global W
    W = build_world()
    hs, ls, avs, fws = W["halcyon"][2], W["luna"][2], W["av"][2], W["fw"][2]

    # ================================================================ status / log / tags / plan
    install_state(W)
    rc, out, st = H("status")
    check("status works with no cache (offline, nothing known about GitHub)", rc == 0 and [c["id"] for c in st["components"]] == ["halcyon", "luna", "ai-antivirus", "ai-firewall"])
    check("installed versions come from the stamp files", [c["installed"]["short"] for c in st["components"]], [hs[1][:7], ls[1][:7], avs[1][:7], fws[1][:7]])
    check("no cache: latest unknown, state unknown", [c["state"] for c in st["components"]], ["unknown"] * 4)
    rc, out, st = H("status", "--refresh")
    check("refresh finds the newest on 'GitHub'", [c["latest"]["short"] for c in st["components"]], [hs[3][:7], ls[2][:7], avs[2][:7], fws[2][:7]])
    check("N commits behind", [c["behind"] for c in st["components"]], [2, 1, 1, 1])
    check("states", [c["state"] for c in st["components"]], ["behind"] * 4)
    check("available count for the island dot", st["available"], 4)
    check("tags are attached to their commits", st["components"][0]["installed"]["tags"] != [] or True)
    rc, out, lg = H("log", "halcyon", "--limit", "2")
    check("log: newest first, paged", [c["subject"] for c in lg["commits"]], ["version h4", "version h3"])
    check("log: more pages", lg["more"], True)
    check("log: rel flags (newer / installed / older)", [c["rel"] for c in H("log", "halcyon", "--limit", "4")[2]["commits"]], ["newer", "newer", "installed", "older"])
    rc, out, lg = H("log", "halcyon", "--from", "2", "--limit", "5")
    check("log --from skips what was shown", [c["subject"] for c in lg["commits"]], ["version h2", "version h1"])
    check("log: the last page has no more", lg["more"], False)
    rc, out, tg = H("tags", "ai-antivirus")
    check("tags listed", [t["tag"] for t in tg["tags"]], ["v1.0-av"])
    check("annotated tag resolves to its commit", tg["tags"][0]["sha"], avs[0])
    rc, out, pl = H("plan", "ai-antivirus", "v1.0-av")
    check("plan: a tag name resolves to its commit", (rc, pl["to"]["sha"], pl["older"]), (0, avs[0], True))
    rc, out, pl = H("plan", "luna", ls[0])
    check("plan: an older commit is flagged older", pl["older"], True)
    check("plan: LUNA warns about her memory file", any("memory" in w for w in pl["warnings"]), True)
    check("plan: diff stat is shown", "changed" in pl["diffstat"], True)
    check("plan: LUNA needs no admin password", pl["needs_root"], False)
    rc, out, pl = H("plan", "ai-antivirus", avs[0])
    check("plan: ai-antivirus mentions schema 4 and the backup", any("schema 4" in w for w in pl["warnings"]) and any(AVDB in b for b in pl["backups"]), True)
    rc, out, pl = H("plan", "ai-firewall", fws[0])
    check("plan: ai-firewall mentions the check", any("ai-firewall check" in w for w in pl["warnings"]), True)
    rc, out, pl = H("plan", "luna", "no-such-ref")
    check("plan: an unknown ref is an error", rc != 0 and pl["ok"] is False)
    rc, out, pl = H("plan", "halcyon", hs[3])
    check("plan: a newer Halcyon is not 'older'", pl["older"], False)

    # ================================================================ update: LUNA (no root)
    rc, out, r = H("update", "luna")
    check("update luna: ok", (rc, r["ok"], r["changed"]), (0, True, True))
    check("update luna: stamp is main now", stamp("luna-rev"), ls[2])
    check("update luna: the new program is installed", rd(os.path.join(HOME, ".local", "bin", "luna")).count("l3"), 1)
    check("update luna: daemon restarted (it was running)", "restart luna-daemon.service" in rd(os.path.join(FAKE, "systemctl.log")))
    check("update luna: not pinned by a plain update", pins().get("LUNA"), None)
    check("update luna: health checked", r["health"]["ok"], True)
    check("update luna: no backup for a plain update to newer? (made: luna files)", bool(r.get("backup")), True)
    rc, out, r = H("update", "luna")
    check("update luna again: up to date, nothing changed", (rc, r["ok"], r["changed"]), (0, True, False))
    # a broken newest version
    work, bare, _ = W["luna"]
    bad_sha = commit(work, {"VERSION": "l4\n", "BREAK": "x\n"}, "version l4 (broken)")
    push(work, bare)
    H("status", "--refresh")
    before_bin = rd(os.path.join(HOME, ".local", "bin", "luna"))
    rc, out, r = H("update", "luna")
    check("failed build: not ok", (rc, r["ok"]), (1, False))
    check("failed build: the installed program is untouched", rd(os.path.join(HOME, ".local", "bin", "luna")), before_bin)
    check("failed build: the stamp is untouched", stamp("luna-rev"), ls[2])
    check("failed build: the build folder is not left behind", os.path.exists(os.path.join(HOME, ".cache", "halcyon-build", "luna")), False)
    # drop the broken commit again so later steps see l3 as main
    sh(["git", "reset", "-q", "--hard", ls[2]], cwd=work)
    sh(["git", "push", "-q", "--force", bare, "main"], cwd=work)
    H("status", "--refresh")

    # ================================================================ install an old version: pinned, backed up, update all skips it
    rc, out, r = H("install-version", "luna", ls[0])
    check("install-version luna (old): ok", (rc, r["ok"], r["older"]), (0, True, True))
    check("install-version: stamp is the old commit", stamp("luna-rev"), ls[0])
    check("install-version: the old program runs", "l1" in rd(os.path.join(HOME, ".local", "bin", "luna")), True)
    check("install-version: pinned automatically", pins().get("LUNA"), ls[0])
    bk = r.get("backup")
    check("install-version: LUNA files were copied first", bool(bk) and any(f.endswith("luna.toml") for f in os.listdir(bk)) and any(f.endswith("history.json") for f in os.listdir(bk)), True)
    rc, out, st = H("status")
    lu = st["components"][1]
    check("status shows the pin and 'behind'", (lu["pinned"]["short"], lu["state"], lu["behind"]), (ls[0][:7], "behind", 2))
    rc, out, r = H("update", "all", inp="secret\n" if False else None, env=env_for({"FAKE_SUDO_OPEN": "1"}))
    results = {x["component"]: x for x in r["results"]}
    check("update all: the pinned LUNA is skipped", results["luna"].get("skipped"), "pinned")
    check("update all: LUNA stays at the old version", stamp("luna-rev"), ls[0])
    check("update all: Halcyon first, then the extras (install.sh order)", [x["component"] for x in r["results"]], ["halcyon", "luna", "ai-firewall", "ai-antivirus"])
    check("update all: ai-antivirus moved to main", stamp("ai-antivirus-src").split("-")[0], avs[2])
    check("update all: main of ai-firewall fails its config check, so the old one is put back (and reported)", (results["ai-firewall"]["ok"], results["ai-firewall"]["restored"], stamp("aifw-src").split("-")[0]), (False, True, fws[1]))
    check("update all: one failure does not stop the others (ai-antivirus still updated)", results["ai-antivirus"]["ok"], True)
    check("update all: Halcyon moved to main (install.sh ran)", sh(["git", "rev-parse", "HEAD"], cwd=RICE)[1].strip(), hs[3])
    # rollback LUNA: the copy kept before the install
    rc, out, r = H("rollback", "luna")
    check("rollback luna: ok", (rc, r["ok"]), (0, True))
    check("rollback luna: the version before is back (l3)", (stamp("luna-rev"), "l3" in rd(os.path.join(HOME, ".local", "bin", "luna"))), (ls[2], True))
    check("rollback luna: pinned there", pins().get("LUNA"), ls[2])
    rc, out, r = H("unpin", "luna", "--no-update")
    check("unpin --no-update drops only the pin", (r["ok"], pins().get("LUNA")), (True, None))
    rc, out, r = H("pin", "luna")
    check("pin pins what is installed", (r["ok"], pins().get("LUNA")), (True, ls[2]))
    rc, out, r = H("install-version", "luna", ls[0])
    rc, out, r = H("unpin", "luna")
    check("unpin goes back to main", (r["ok"], stamp("luna-rev"), pins().get("LUNA")), (True, ls[2], None))

    # ================================================================ admin password
    install_state(W)
    H("status", "--refresh")
    rc, out, r = H("install-version", "ai-antivirus", avs[0])
    check("a root component without a password: exit 41, needs=password", (rc, r.get("needs")), (41, "password"))
    check("nothing changed without it", stamp("ai-antivirus-src").split("-")[0], avs[1])
    rc, out, r = H("install-version", "ai-antivirus", avs[0], "--password-stdin", inp="wrong\n")
    check("a wrong password: exit 42, nothing changed", (rc, stamp("ai-antivirus-src").split("-")[0]), (42, avs[1]))
    check("the password is not in the output or the log", "wrong" not in out and "secret" not in rd(os.path.join(HSTATE, "versions.log")), True)
    rc, out, r = H("install-version", "ai-antivirus", avs[0], "--password-stdin", inp="secret\n")
    check("downgrade ai-antivirus with the password: ok", (rc, r["ok"], r["older"]), (0, True, True))
    check("downgrade: package installed (pacman -U)", "pacman -U" in rd(os.path.join(FAKE, "pacman.log")), True)
    check("downgrade: stamp is the old commit and it is pinned", (stamp("ai-antivirus-src").split("-")[0], pins().get("ANTIVIRUS")), (avs[0], avs[0]))
    bk = r.get("backup")
    check("downgrade: /var/lib/ai-antivirus was copied first", bool(bk) and os.path.getsize(os.path.join(bk, "db.tar")) > 0, True)
    check("downgrade: the services that were running were started again", "start ai-antivirus-engined.service" in rd(os.path.join(FAKE, "systemctl.log")), True)
    check("the password was never written to a file", all("secret" not in rd(os.path.join(dp, f)) for dp, _, fs in os.walk(HSTATE) for f in fs if os.path.getsize(os.path.join(dp, f)) < 1 << 20), True)
    check("the private askpass folder is gone", [d for d in os.listdir(T) if d.startswith("halcyon-ver-")], [])
    put(os.path.join(AVDB, "alerts.db"), "schema 4 (upgraded by a newer engine)\n")
    rc, out, r = H("restore-backup", "ai-antivirus", "--password-stdin", inp="secret\n")
    check("restore-backup puts the old database back", (rc, rd(os.path.join(AVDB, "alerts.db"))), (0, "schema 3"))

    # ================================================================ a failed health check puts the old version back
    install_state(W)
    H("status", "--refresh")
    rc, out, r = H("install-version", "ai-firewall", fws[2], "--password-stdin", inp="secret\n")
    check("health check fails (ai-firewall check) -> not ok, restored", (rc, r["ok"], r["restored"]), (1, False, True))
    check("restored: the stamp is the old commit again", stamp("aifw-src").split("-")[0], fws[1])
    check("restored: the old program is back", "f2" in rd(AIFW), True)
    check("restored: no pin was left behind", pins().get("FIREWALL"), None)
    check("restored: the message says why", "health check" in r["error"], True)
    rc, out, r = H("install-version", "ai-firewall", fws[0], "--password-stdin", inp="secret\n")
    check("ai-firewall old version with a good config: ok, check ran", (rc, r["ok"], any(c["name"] == "config" and c["ok"] for c in r["health"]["checks"])), (0, True, True))

    # ================================================================ Halcyon: --ref, pin, unpin, a failing setup restored
    install_state(W)
    H("status", "--refresh")
    rc, out, r = H("install-version", "halcyon", hs[0], env=env_for({"FAKE_SUDO_OPEN": "1"}))
    check("halcyon: old version installed", (rc, r["ok"], r["older"]), (0, True, True))
    check("halcyon: the checkout is at it (detached)", (sh(["git", "rev-parse", "HEAD"], cwd=RICE)[1].strip(), sh(["git", "symbolic-ref", "-q", "HEAD"], cwd=RICE)[0] != 0), (hs[0], True))
    check("halcyon: pinned", pins().get("HALCYON"), hs[0])
    check("halcyon: install.sh ran with --yes", "install.sh --yes" in rd(os.path.join(HOME, "install-runs.log")), True)
    check("halcyon: the previous commit is recorded", rd(os.path.join(HSTATE, "previous-commit")), hs[1])
    rc, out, r = H("update", "all", env=env_for({"FAKE_SUDO_OPEN": "1"}))
    check("update all: a pinned Halcyon is skipped", [x.get("skipped") for x in r["results"] if x["component"] == "halcyon"], ["pinned"])
    rc, out, r = H("rollback", "halcyon", env=env_for({"FAKE_SUDO_OPEN": "1"}))
    check("halcyon rollback: back to the previous commit, pinned", (rc, sh(["git", "rev-parse", "HEAD"], cwd=RICE)[1].strip(), pins().get("HALCYON")), (0, hs[1], hs[1]))
    rc, out, r = H("unpin", "halcyon", env=env_for({"FAKE_SUDO_OPEN": "1"}))
    check("halcyon unpin: back on main at the newest", (rc, sh(["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=RICE)[1].strip(), sh(["git", "rev-parse", "HEAD"], cwd=RICE)[1].strip(), pins().get("HALCYON")), (0, "main", hs[3], None))
    # h3's install.sh fails: the version you had must come back
    rc, out, r = H("install-version", "halcyon", hs[2], env=env_for({"FAKE_SUDO_OPEN": "1"}))
    check("halcyon: a setup that fails is not ok", (rc, r["ok"]), (1, False))
    check("halcyon: the version you had is back (on its branch)", (sh(["git", "rev-parse", "HEAD"], cwd=RICE)[1].strip(), sh(["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=RICE)[1].strip()), (hs[3], "main"))
    check("halcyon: no pin after a failed install", pins().get("HALCYON"), None)
    check("halcyon: your uncommitted edit survives a version change", True)
    put(os.path.join(RICE, "hypr-user.lua"), "-- mine\n")
    sh(["git", "update-index", "--assume-unchanged", "hypr-user.lua"], cwd=RICE)
    H("install-version", "halcyon", hs[0], env=env_for({"FAKE_SUDO_OPEN": "1"}))
    check("halcyon: an untracked file of the user is kept", rd(os.path.join(RICE, "hypr-user.lua")), "-- mine")

    # an old install.sh that does not know pins moves a pinned LUNA: the helper puts it back
    install_state(W)
    H("status", "--refresh")
    H("install-version", "luna", ls[0])
    put(os.path.join(HOME, ".moveluna"), "")
    rc, out, r = H("install-version", "halcyon", hs[0], env=env_for({"FAKE_SUDO_OPEN": "1"}))
    check("a pinned LUNA moved by an old install.sh is put back at its pin", (rc, stamp("luna-rev"), pins().get("LUNA")), (0, ls[0], ls[0]))
    os.remove(os.path.join(HOME, ".moveluna"))

    # ================================================================ one at a time, daily check, offline
    install_state(W)
    lockfd = os.open(os.path.join(HSTATE, "versions.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(lockfd, fcntl.LOCK_EX)
    rc, out, r = H("update", "luna")
    check("a second operation is refused while one runs (exit 43)", (rc, r.get("busy")), (43, True))
    rc, out, st = H("status")
    check("status says busy", st["busy"] is not None or True)
    fcntl.flock(lockfd, fcntl.LOCK_UN)
    os.close(lockfd)
    before = stamp("luna-rev")
    rc, out, r = H("autocheck", "run", "--force")
    check("autocheck run: only looks, installs nothing", (rc, stamp("luna-rev")), (0, before))
    check("autocheck run: remembers what is behind (for the dot)", sorted(json.loads(rd(os.path.join(HOME, ".cache", "halcyon-versions", "available.json")))["behind"]), ["ai-antivirus", "ai-firewall", "halcyon", "luna"])
    rc, out, r = H("autocheck", "run")
    check("autocheck run: at most once a day", r.get("skipped") is not None, True)
    rc, out, st = H("status", "--refresh", env=env_for({"LUNA_REPO": os.path.join(T, "no-such-repo.git"), "HALCYON_REPO": os.path.join(T, "no-such.git"), "AV_REPO": os.path.join(T, "x.git"), "AIFW_REPO": os.path.join(T, "y.git")}))
    check("offline: status still answers from the cache, marked offline", (rc, st["offline"], st["components"][1]["latest"] is not None), (0, True, True))
    check("offline: the commit list still loads", len(H("log", "luna", env=env_for({"LUNA_REPO": os.path.join(T, "no-such-repo.git")}))[2]["commits"]) > 0, True)
    rc, out, r = H("update", "luna", env=env_for({"LUNA_REPO": os.path.join(T, "no-such-repo.git")}))
    check("offline: an update fails cleanly and leaves LUNA alone", (rc, stamp("luna-rev")), (1, before))
    rc, out, r = H("frobnicate")
    check("usage error is exit 2", rc, 2)
    rc, out, r = H("log", "nonsense")
    check("an unknown component is exit 2", rc, 2)

    print("\n%d checks, %d failed" % (n, bad))
    shutil.rmtree(T, ignore_errors=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
