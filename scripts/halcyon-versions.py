#!/usr/bin/env python3
"""halcyon-versions.py: the backend of the Version Center (>versions in the launcher, Settings > Version Center).

Halcyon and its three companions (LUNA, ai-antivirus, ai-firewall): which version is installed, what is newest on GitHub, the commit
list, and the actions that move between versions. It builds nothing itself: every install goes through the scripts that already
do it (update.sh for Halcyon, scripts/update-extras.sh for the three, install.sh for a component not installed yet), so the window
and the command line always do the same thing and the same stamp files (~/.local/state/island/luna-rev, ai-antivirus-src, aifw-src,
install-choices.env) say what is installed.

  status [--refresh]                  all four components as JSON: installed, latest, behind, pinned, chosen (--refresh asks GitHub first)
  log <component> [--from N] [--limit 30]   commits, newest first, paged (from the cached history; no network)
  tags <component>                    the tags, newest first
  plan <component> <ref>              what installing <ref> would do: diff stat, older-than-installed, backups, warnings (for the confirm dialog)
  update <component|all> [--ref X]    the newest main (pinned components are skipped by `all`); --ref = install-version
  install-version <component> <ref>   exactly that commit or tag; the component is pinned to it
  rollback <component>                the version before the last change (kept copy, or the recorded commit); pins it
  pin <component> / unpin <component> [--no-update]   unpin returns to main (and updates to it)
  health <component>                  service active, binary matches the build, ai-firewall check, ai-antivirus status, island log
  backups <component> / restore-backup <component> [dir]   the copies made before a change (ai-antivirus: /var/lib/ai-antivirus)
  autocheck on|off|status|run         the optional daily look (a systemd user timer, off by default); `run` only checks, never installs

  options: --password-stdin   the first line of stdin is the admin password (asked once, kept in memory only, never written anywhere)
           --yes              accepted for symmetry with the scripts; nothing here asks questions
Output: JSON on stdout. update / install-version / rollback / unpin stream the build output line by line, then one last line
`##result {json}`; `##step <text>` lines mark the stages. Everything is also appended to ~/.local/state/halcyon/versions.log.
One operation at a time (flock). Exit code: 0 ok, 1 failed, 2 usage, 41 the admin password is needed, 42 the password was wrong, 43 busy.
Environment (tests, forks): HALCYON_DIR, HALCYON_REPO / LUNA_REPO / AV_REPO / AIFW_REPO, AIFW_BIN, AV_BIN, AV_DB_DIR, HALCYON_VERSIONS_NET.
"""
import argparse
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR") or os.path.join(HOME, ".config", "Halcyon")
ISTATE = os.path.join(HOME, ".local", "state", "island")       # stamps + install-choices.env (what install.sh writes)
HSTATE = os.path.join(HOME, ".local", "state", "halcyon")      # pins.env, versions.log, backups, previous-commit
CACHE = os.path.join(HOME, ".cache", "halcyon-versions")       # bare clones for the history, status cache
SRC = os.path.join(HOME, ".local", "src")
BUILD_BIN = os.path.join(HOME, ".local", "bin")
ISLAND_LOG = os.path.join(HOME, ".cache", "island", "quickshell-island.log")
NET = int(os.environ.get("HALCYON_VERSIONS_NET", "20"))        # seconds a network step may take (update.sh uses 20 too)
AIFW_BIN = os.environ.get("AIFW_BIN", "/usr/local/bin/ai-firewall")
AV_DB_DIR = os.environ.get("AV_DB_DIR", "/var/lib/ai-antivirus")
AV_BIN = os.environ.get("AV_BIN", "/usr/bin/ai-antivirus")
AV_UNITS = ["engined", "sensord", "responderd", "analyzer"]
EMPTY_STATUS_HASH = "e3b0c44298fc"                              # sha256 of "": a clean checkout's stamp ends with this
PAGE = 30

# display order is the window's; UPDATE_ORDER is install.sh's (Halcyon, then LUNA, ai-firewall, ai-antivirus)
COMPONENTS = {
    "halcyon": dict(name="Halcyon", key="HALCYON", env="HALCYON_REPO", repo="https://github.com/X-netrunner/Halcyon", root=True),
    "luna": dict(name="LUNA", key="LUNA", env="LUNA_REPO", repo="https://github.com/X-netrunner/LUNA-AI.git", stamp="luna-rev", root=False),
    "ai-antivirus": dict(name="ai-antivirus", key="ANTIVIRUS", env="AV_REPO", repo="https://github.com/X-netrunner/ai-antivirus", stamp="ai-antivirus-src", root=True),
    "ai-firewall": dict(name="ai-firewall", key="FIREWALL", env="AIFW_REPO", repo="https://github.com/X-netrunner/ai-firewall.git", stamp="aifw-src", root=True),
}
DISPLAY_ORDER = ["halcyon", "luna", "ai-antivirus", "ai-firewall"]
UPDATE_ORDER = ["halcyon", "luna", "ai-firewall", "ai-antivirus"]
INSTALL_FLAG = {"luna": ["--luna"], "ai-antivirus": ["--antivirus"], "ai-firewall": ["--firewall", "ai"]}


class Fail(Exception):
    def __init__(self, msg, code=1, needs=None):
        super().__init__(msg)
        self.code = code
        self.needs = needs


# ------------------------------------------------------------------ small helpers
def now():
    return int(time.time())


def jprint(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def env_file(path):
    """KEY="value" lines (install-choices.env, pins.env) -> dict; the last line of a key wins."""
    d = {}
    for line in read(path).splitlines():
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)="(.*)"$', line.strip())
        if m:
            d[m.group(1)] = m.group(2)
    return d


def choices():
    return env_file(os.path.join(ISTATE, "install-choices.env"))


def pins():
    return env_file(os.path.join(HSTATE, "pins.env"))


def pin_set(c, sha):
    p = os.path.join(HSTATE, "pins.env")
    key = COMPONENTS[c]["key"]
    lines = [l for l in read(p).splitlines() if not l.startswith(key + "=")]
    lines.append('%s="%s"' % (key, sha))
    write(p, "\n".join(lines) + "\n")


def pin_del(c):
    p = os.path.join(HSTATE, "pins.env")
    if not os.path.exists(p):
        return
    key = COMPONENTS[c]["key"]
    lines = [l for l in read(p).splitlines() if not l.startswith(key + "=")]
    write(p, "\n".join(lines) + ("\n" if lines else ""))


def repo_url(c):
    d = COMPONENTS[c]
    return os.environ.get(d["env"]) or d["repo"]


def is_sha(s):
    return bool(s) and re.fullmatch(r"[0-9a-f]{40}", s) is not None


def short(s):
    return (s or "")[:7]


def run(cmd, timeout=30, cwd=None, env=None, inp=None):
    """(returncode, stdout) of a short command; a missing program or a timeout is rc 127 / 124."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env, input=inp)
        return p.returncode, (p.stdout or "") + ("" if p.returncode == 0 else (p.stderr or ""))
    except (FileNotFoundError, PermissionError):
        return 127, ""
    except subprocess.TimeoutExpired:
        return 124, ""


def git(repo, *args, timeout=NET):
    return run(["git", "--git-dir", repo] + list(args), timeout=timeout, env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))


# ------------------------------------------------------------------ what is installed
def have_pacman_pkg(name):
    return shutil.which("pacman") is not None and run(["pacman", "-Q", name], timeout=10)[0] == 0


def installed(c):
    """{present, sha, stamp, source, dirty, managed}: from the same stamp files install.sh / update-extras.sh write."""
    d = COMPONENTS[c]
    out = dict(present=False, sha=None, stamp="", source="unknown", dirty=False, managed="")
    if c == "halcyon":
        git_dir = os.path.join(RICE, ".git")
        if os.path.isdir(git_dir):
            rc, o = run(["git", "-C", RICE, "rev-parse", "HEAD"], timeout=10)
            out.update(present=True, sha=o.strip() if rc == 0 and is_sha(o.strip()) else None, source="git")
        elif os.path.isdir(RICE):
            sha = read(os.path.join(HSTATE, "installed-commit"))
            out.update(present=True, sha=sha if is_sha(sha) else None, source="copy")
        out["stamp"] = out["sha"] or ""
        return out
    stamp = read(os.path.join(ISTATE, d["stamp"]))
    out["stamp"] = stamp
    sha = stamp.split("-")[0] if stamp else ""
    out["sha"] = sha if is_sha(sha) else None
    out["source"] = "git" if out["sha"] else ("local" if stamp else "unknown")
    if "-" in stamp and out["sha"]:
        out["dirty"] = stamp.split("-", 1)[1] != EMPTY_STATUS_HASH
    if c == "luna":
        out["present"] = os.access(os.path.join(BUILD_BIN, "luna"), os.X_OK)
    elif c == "ai-antivirus":
        out["present"] = have_pacman_pkg("ai-antivirus")
    else:
        if have_pacman_pkg("ai-firewall") or have_pacman_pkg("ai-firewall-git"):
            out.update(present=True, managed="pacman")
        else:
            out["present"] = os.access(AIFW_BIN, os.X_OK)
    return out


def chosen(c):
    ch = choices()
    if c == "halcyon":
        return True
    if c == "luna":
        return ch.get("LUNA") == "yes"
    if c == "ai-antivirus":
        return ch.get("ANTIVIRUS") == "yes" or (not ch.get("ANTIVIRUS") and ch.get("SYNAPSE") == "yes")
    return ch.get("FIREWALL") == "ai"


# ------------------------------------------------------------------ the cached history (a bare clone per component)
def cache_repo(c):
    return os.path.join(CACHE, c + ".git")


def cache_state():
    try:
        return json.loads(read(os.path.join(CACHE, "state.json")) or "{}")
    except ValueError:
        return {}


def set_cache_state(c, **kw):
    st = cache_state()
    st.setdefault(c, {}).update(kw)
    write(os.path.join(CACHE, "state.json"), json.dumps(st))


def refresh_cache(c):
    """Fetch the component's history from GitHub into the bare clone. True = reached it; False = offline / rate limited (the old cache stays)."""
    repo, url = cache_repo(c), repo_url(c)
    os.makedirs(CACHE, exist_ok=True)
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    if not os.path.isdir(repo):
        cmd = ["git", "clone", "--bare", "--quiet"] + (["--filter=blob:none"] if url.startswith("https://") else []) + [url, repo]
        rc, _ = run(cmd, timeout=300, env=env)
        if rc != 0:
            shutil.rmtree(repo, ignore_errors=True)
            set_cache_state(c, offline=True)
            return False
    else:
        rc, _ = run(["git", "--git-dir", repo, "fetch", "--quiet", "--tags", "--force", url, "+refs/heads/*:refs/heads/*"], timeout=NET, env=env)
        if rc != 0:
            set_cache_state(c, offline=True)
            return False
        # the default branch can move: HEAD follows what the remote says
        rc, o = run(["git", "ls-remote", "--symref", url, "HEAD"], timeout=NET, env=env)
        m = re.search(r"^ref: refs/heads/(\S+)\s+HEAD$", o, re.M) if rc == 0 else None
        if m:
            git(repo, "symbolic-ref", "HEAD", "refs/heads/" + m.group(1))
    set_cache_state(c, offline=False, checked=now())
    return True


def have_cache(c):
    return os.path.isdir(cache_repo(c)) and git(cache_repo(c), "rev-parse", "--verify", "--quiet", "HEAD")[0] == 0


FMT = "%H%x1f%h%x1f%s%x1f%cI%x1f%ct%x1f%an"


def parse_commit(line):
    f = line.split("\x1f")
    if len(f) < 6:
        return None
    return dict(sha=f[0], short=f[1], subject=f[2], date=f[3], unix=int(f[4] or 0), author=f[5])


def tag_map(c):
    """sha -> [tags] (annotated tags are followed to their commit)."""
    rc, o = git(cache_repo(c), "for-each-ref", "refs/tags", "--format=%(objectname) %(*objectname) %(refname:short)")
    m = {}
    if rc != 0:
        return m
    for line in o.splitlines():
        parts = line.split()
        if len(parts) == 3:
            m.setdefault(parts[1], []).append(parts[2])
        elif len(parts) == 2:
            m.setdefault(parts[0], []).append(parts[1])
    return m


def commit_info(c, sha, tmap=None):
    if not sha or not have_cache(c):
        return None
    rc, o = git(cache_repo(c), "show", "-s", "--format=" + FMT, sha)
    if rc != 0:
        return None
    ci = parse_commit(o.strip())
    if ci:
        ci["tags"] = (tmap if tmap is not None else tag_map(c)).get(ci["sha"], [])
    return ci


def in_cache(c, sha):
    return bool(sha) and have_cache(c) and git(cache_repo(c), "cat-file", "-e", sha + "^{commit}")[0] == 0


def resolve(c, ref):
    """A commit or tag name -> the full sha (from the cached history), or None."""
    if not have_cache(c) or not re.fullmatch(r"[A-Za-z0-9._/+-]+", ref or ""):
        return None
    rc, o = git(cache_repo(c), "rev-parse", "--verify", "--quiet", ref + "^{commit}")
    return o.strip() if rc == 0 and is_sha(o.strip()) else None


# ------------------------------------------------------------------ status
def busy_info():
    p = os.path.join(HSTATE, "versions.busy")
    try:
        return json.loads(read(p)) if os.path.exists(p) else None
    except ValueError:
        return None


def lock_is_free():
    os.makedirs(HSTATE, exist_ok=True)
    fd = os.open(os.path.join(HSTATE, "versions.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def local_edits(sha):
    """How many files of the Halcyon install differ from the installed commit (0 when it cannot be told). A dev build copied over an install,
    or edited in place, still carries the old commit id; this is what tells those apart from a clean install of that commit."""
    if not sha or not os.path.isdir(RICE):
        return 0
    if os.path.isdir(os.path.join(RICE, ".git")):
        rc, o = run(["git", "-C", RICE, "status", "--porcelain", "-uno"], timeout=15)
        return len([l for l in o.splitlines() if l.strip()]) if rc == 0 else 0
    if not have_cache("halcyon"):
        return 0
    rc, o = git(cache_repo("halcyon"), "ls-tree", "-r", sha, timeout=15)
    if rc != 0:
        return 0
    want = []
    for line in o.splitlines():
        meta, _, path = line.partition("\t")
        parts = meta.split()
        if len(parts) == 3 and parts[1] == "blob" and parts[0] in ("100644", "100755"):
            full = os.path.join(RICE, path)
            if os.path.isfile(full) and not os.path.islink(full):
                want.append((path, parts[2]))
    if not want:
        return 0
    rc, o = run(["git", "hash-object", "--no-filters", "--stdin-paths"], timeout=30, cwd=RICE, inp="\n".join(p for p, _ in want) + "\n")
    got = o.split()
    if rc != 0 or len(got) != len(want):
        return 0
    return sum(1 for (_, h), g in zip(want, got) if h != g)


def component_status(c, tmap=None):
    d = COMPONENTS[c]
    inst = installed(c)
    ch = chosen(c)
    pin = pins().get(d["key"], "")
    cs = cache_state().get(c, {})
    st = dict(id=c, name=d["name"], chosen=ch, present=inst["present"], needs_root=d["root"], source=inst["source"], dirty=inst["dirty"],
              managed=inst["managed"], offline=bool(cs.get("offline")), checked=cs.get("checked", 0),
              pinned=dict(sha=pin, short=short(pin)) if pin else None, installed=None, latest=None, behind=None, ahead=None)
    if have_cache(c):
        tmap = tmap if tmap is not None else tag_map(c)
        rc, o = git(cache_repo(c), "rev-parse", "HEAD")
        st["latest"] = commit_info(c, o.strip(), tmap) if rc == 0 else None
        if inst["sha"]:
            ci = commit_info(c, inst["sha"], tmap)
            if ci:
                st["installed"] = ci
                if st["latest"]:
                    rc, n = git(cache_repo(c), "rev-list", "--count", "%s..HEAD" % inst["sha"])
                    st["behind"] = int(n.strip()) if rc == 0 and n.strip().isdigit() else None
                    rc, n = git(cache_repo(c), "rev-list", "--count", "HEAD..%s" % inst["sha"])
                    st["ahead"] = int(n.strip()) if rc == 0 and n.strip().isdigit() else None
    if c == "halcyon" and inst["present"] and inst["sha"]:
        n = local_edits(inst["sha"])
        if n:
            inst["dirty"] = True
            st["dirty"] = True
            st["edited_files"] = n
    prev = previous_version(c)
    st["previous"] = dict(sha=prev, short=short(prev)) if prev and prev != inst["sha"] else None
    if inst["sha"] and not st["installed"]:
        st["installed"] = dict(sha=inst["sha"], short=short(inst["sha"]), subject="", date="", unix=0, author="", tags=[], unknown=True)
    if not ch and not inst["present"]:
        state = "not-chosen"
    elif not inst["present"]:
        state = "missing"
    elif inst["managed"] == "pacman":
        state = "pacman"
    elif not inst["sha"]:
        state = "local"
    elif st["installed"] and st["installed"].get("unknown") and have_cache(c) and not st["offline"]:
        state = "unreg"                 # the installed commit is not in the repo's history (GitHub was reached): not a registered version
    elif st["behind"] is None:
        state = "unknown"
    else:
        state = "behind" if st["behind"] > 0 else ("ahead" if st["ahead"] else "up-to-date")
    st["state"] = state
    return st


def cmd_status(a):
    if a.refresh:
        for c in DISPLAY_ORDER:
            if c == "halcyon" or chosen(c) or installed(c)["present"]:
                refresh_cache(c)
    comps = [component_status(c) for c in DISPLAY_ORDER]
    cs = cache_state()
    checked = max([cs.get(c, {}).get("checked", 0) for c in DISPLAY_ORDER] + [0])
    jprint(dict(components=comps, checked=checked, offline=any(x["offline"] for x in comps if x["chosen"] or x["present"]),
                busy=busy_info() if not lock_is_free() else None, autocheck=autocheck_state(),
                available=sum(1 for x in comps if x["state"] == "behind" and not x["pinned"])))
    return 0


def cmd_log(a):
    c = need_comp(a.component)
    if not have_cache(c):
        refresh_cache(c)
    if not have_cache(c):
        jprint(dict(commits=[], more=False, offline=True))
        return 0
    inst = installed(c)["sha"]
    tmap = tag_map(c)
    ahead = set()
    if inst and in_cache(c, inst):
        rc, o = git(cache_repo(c), "rev-list", "HEAD", "^" + inst)
        ahead = set(o.split()) if rc == 0 else set()
    limit = max(1, min(100, a.limit))
    rc, o = git(cache_repo(c), "log", "-n", str(limit + 1), "--skip", str(max(0, a.frm)), "--format=" + FMT + "%x1e", "HEAD")
    commits = []
    for rec in (o.split("\x1e") if rc == 0 else []):
        ci = parse_commit(rec.strip("\n"))
        if not ci:
            continue
        ci["tags"] = tmap.get(ci["sha"], [])
        ci["rel"] = "installed" if ci["sha"] == inst else ("newer" if ci["sha"] in ahead else ("older" if inst and in_cache(c, inst) else ""))
        commits.append(ci)
    more = len(commits) > limit
    jprint(dict(commits=commits[:limit], more=more, offline=bool(cache_state().get(c, {}).get("offline")), installed=inst))
    return 0


def cmd_tags(a):
    c = need_comp(a.component)
    if not have_cache(c):
        refresh_cache(c)
    out = []
    if have_cache(c):
        rc, o = git(cache_repo(c), "for-each-ref", "--sort=-creatordate", "refs/tags", "--format=%(refname:short)%1f%(objectname)%1f%(*objectname)%1f%(creatordate:iso-strict)")
        for line in (o.splitlines() if rc == 0 else []):
            f = line.split("\x1f")
            if len(f) == 4:
                out.append(dict(tag=f[0], sha=f[2] or f[1], date=f[3]))
    jprint(dict(tags=out[:60]))
    return 0


def need_comp(name):
    if name not in COMPONENTS:
        raise Fail("unknown component: %s (halcyon, luna, ai-antivirus, ai-firewall)" % name, 2)
    return name


# ------------------------------------------------------------------ plan (the confirm dialog)
def backup_list(c):
    if c == "ai-antivirus":
        return ["%s (the whole folder, copied before the change; services stop for a moment)" % AV_DB_DIR]
    if c == "ai-firewall":
        return ["/etc/ai-firewall (the config)"]
    if c == "luna":
        return ["~/.config/luna/luna.toml", "her memory file (history.json) and conversations"]
    return ["~/.config/Halcyon-backups keeps the copy install.sh makes; hypr-user.lua, scheme/current.lua and your other own files stay"]


def cmd_plan(a):
    c = need_comp(a.component)
    if not have_cache(c):
        refresh_cache(c)
    sha = resolve(c, a.ref)
    if not sha:
        raise Fail("%s is not a commit or tag of %s (check the name, or press Check now)" % (a.ref, COMPONENTS[c]["name"]))
    inst = installed(c)
    cur = inst["sha"]
    tmap = tag_map(c)
    warns, older, stat, between = [], False, "", None
    if cur and in_cache(c, cur):
        if cur == sha:
            warns.append("This is the version already installed.")
        older = git(cache_repo(c), "merge-base", "--is-ancestor", sha, cur)[0] == 0 and cur != sha
        rc, o = git(cache_repo(c), "diff", "--shortstat", cur, sha, timeout=NET)
        stat = o.strip() if rc == 0 else ""
        rc, n = git(cache_repo(c), "rev-list", "--count", ("%s..%s" % (sha, cur)) if older else ("%s..%s" % (cur, sha)))
        between = int(n.strip()) if rc == 0 and n.strip().isdigit() else None
    else:
        warns.append("The installed version is not in the history here (a local build?), so no difference can be shown.")
    if older:
        warns.append("This version is OLDER than the one installed.")
        if c == "ai-antivirus":
            warns.append("Its database is upgraded the first time a newer engine starts (schema 4). An older engine may not read it. %s is copied first, and the copy can be restored here afterwards." % AV_DB_DIR)
        elif c == "ai-firewall":
            warns.append("Its config and BPF pins may differ between versions. `ai-firewall check` runs afterwards; if it fails, the version you have now is put back automatically.")
        elif c == "luna":
            warns.append("luna.toml and her memory file are copied first. An older LUNA may not read a newer memory file.")
        else:
            warns.append("Settings written by the newer Halcyon may not be understood by the older one. install.sh keeps your copy in ~/.config/Halcyon-backups.")
    if c == "halcyon" and have_cache(c) and not git(cache_repo(c), "ls-tree", "--name-only", sha, "scripts/halcyon-versions.py")[1].strip():
        warns.append("That version has no Version Center. Afterwards go back from a terminal:  cd ~/.config/Halcyon && git switch main && ./update.sh")
    if inst["dirty"]:
        warns.append("The installed build had uncommitted changes (a local edit); they are not in any commit and will be gone.")
    if COMPONENTS[c]["root"]:
        warns.append("Needs the administrator password (asked once, never stored).")
    pin = pins().get(COMPONENTS[c]["key"])
    jprint(dict(component=c, to=commit_info(c, sha, tmap), **{"from": commit_info(c, cur, tmap) if cur else None}, older=older, same=(cur == sha),
                diffstat=stat, commits_between=between, warnings=warns, backups=backup_list(c), needs_root=COMPONENTS[c]["root"],
                pinned=bool(pin), will_pin=True))
    return 0


# ------------------------------------------------------------------ the admin password: in memory, handed to sudo through a private FIFO
class Sudo:
    """sudo with no terminal asks SUDO_ASKPASS. The program is a tiny script that connects to a unix socket in a private (0700) folder;
    a thread here answers each connection with the password (one connection = one answer, only to this user: SO_PEERCRED). The password
    lives in this process only: not in a file, not in the environment, not on a command line. It is tried once up front (one answer
    only, so a wrong password cannot lock the account); after that it is handed out whenever a later sudo asks."""

    def __init__(self):
        self.dir = None
        self.pw = None
        self.allow = 0
        self.srv = None
        self.thread = None

    def start(self, pw):
        import socket
        base = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
        self.dir = tempfile.mkdtemp(prefix="halcyon-ver-", dir=base)
        os.chmod(self.dir, 0o700)
        self.sock = os.path.join(self.dir, "pw.sock")
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.sock)
        os.chmod(self.sock, 0o600)
        self.srv.listen(8)
        self.script = os.path.join(self.dir, "askpass")
        with open(self.script, "w") as f:
            f.write('#!%s\nimport socket, sys\nc = socket.socket(socket.AF_UNIX)\nc.connect(%r)\nsys.stdout.write(c.makefile().read())\n' % (sys.executable, self.sock))
        os.chmod(self.script, 0o700)
        self.pw = pw
        self.allow = 1                       # one try
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()
        rc, out = run(["sudo", "-A", "-v"], timeout=30, env=dict(os.environ, SUDO_ASKPASS=self.script))
        if rc != 0:
            self.cleanup()
            if re.search(r"not in the sudoers|may not run sudo|not allowed", out):
                raise Fail("This user is not allowed to use sudo.", 1)
            if rc == 127:
                raise Fail("sudo is not installed.", 1)
            raise Fail("That password did not work.", 42)
        self.allow = 80

    def _serve(self):
        import socket
        import struct
        while self.srv is not None:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            try:
                cred = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
                uid = struct.unpack("3i", cred)[1]
                if uid == os.getuid() and self.pw is not None and self.allow > 0:
                    self.allow -= 1
                    conn.sendall((self.pw + "\n").encode())
            except OSError:
                pass
            finally:
                conn.close()

    def env(self):
        return {"SUDO_ASKPASS": self.script}

    def cleanup(self):
        srv, self.srv = self.srv, None
        if srv is not None:
            try:
                srv.close()
            except OSError:
                pass
        if self.dir:
            shutil.rmtree(self.dir, ignore_errors=True)
            self.dir = None
        self.pw = None


SUDO = Sudo()
ENV_EXTRA = {}
HAS_PASSWORD = False


def sudo_cmd(args):
    """sudo for the helper's own root steps: -A (the private askpass) when a password was given, else -n (never wait for a prompt nobody sees)."""
    return ["sudo", "-A" if HAS_PASSWORD else "-n"] + list(args)


def sudo_cached():
    return run(["sudo", "-n", "true"], timeout=10)[0] == 0


def prepare_root(c, a):
    """The admin password, when this component needs root: given on stdin (--password-stdin), or sudo already allows it, or a terminal can ask."""
    global HAS_PASSWORD
    if not COMPONENTS[c]["root"] or HAS_PASSWORD:
        return
    if getattr(a, "password_stdin", False):
        pw = sys.stdin.readline().rstrip("\n")
        if not pw:
            raise Fail("The admin password is needed.", 41, "password")
        SUDO.start(pw)
        ENV_EXTRA.update(SUDO.env())
        HAS_PASSWORD = True
        return
    if sudo_cached() or sys.stdin.isatty():
        return
    raise Fail("The admin password is needed.", 41, "password")


# ------------------------------------------------------------------ logging and running the real scripts
LOG = None
CHILD = None


def say(line):
    line = line.rstrip("\n")
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    if LOG:
        LOG.write(line + "\n")
        LOG.flush()


def step(text):
    say("##step " + text)


def stream(cmd, cwd=None):
    """Run a script, stream its output line by line (also into versions.log); returns its exit code."""
    global CHILD
    say("$ " + " ".join(cmd))
    env = dict(os.environ, **ENV_EXTRA)
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        CHILD = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True, bufsize=1,
                                 cwd=cwd, env=env, start_new_session=HAS_PASSWORD or not sys.stdin.isatty())
    except FileNotFoundError as e:
        say("could not start %s: %s" % (cmd[0], e))
        return 127
    for line in CHILD.stdout:
        say(line)
    rc = CHILD.wait()
    CHILD = None
    return rc


def kill_child(*_):
    global CHILD
    if CHILD is not None:
        try:
            if os.getpgid(CHILD.pid) == os.getpgrp():
                CHILD.terminate()
            else:
                os.killpg(os.getpgid(CHILD.pid), signal.SIGTERM)
        except OSError:
            try:
                CHILD.terminate()
            except OSError:
                pass
    SUDO.cleanup()
    sys.stdout.write("##result " + json.dumps(dict(ok=False, error="cancelled")) + "\n")
    sys.stdout.flush()
    release_busy()
    os._exit(143)


def script(name):
    p = os.path.join(RICE, name)
    if not os.path.isfile(p):
        raise Fail("%s is missing" % p)
    return p


def island_size():
    try:
        return os.path.getsize(ISLAND_LOG)
    except OSError:
        return 0


BAD_LOG = re.compile(r"ERROR|is not a type|unavailable|Cannot assign|PROBLEM", re.I)


def island_errors(since):
    try:
        with open(ISLAND_LOG, "rb") as f:
            size = os.path.getsize(ISLAND_LOG)
            f.seek(since if since <= size else 0)
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    return [l for l in text.splitlines() if BAD_LOG.search(l)][:8]


# ------------------------------------------------------------------ health checks
def sha256_file(p):
    import hashlib
    try:
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def binary_check(c, path):
    want = read(os.path.join(HSTATE, "bin-%s.sha" % c))
    got = sha256_file(path)
    if not got:
        return dict(name="binary", ok=False, detail="%s is missing" % path)
    if not want:
        return dict(name="binary", ok=True, detail="no build hash was recorded (an install by hand)")
    return dict(name="binary", ok=(want == got), detail="matches the build" if want == got else "differs from the build that was installed")


def unit_active(unit, user=False):
    return run(["systemctl"] + (["--user"] if user else []) + ["is-active", "--quiet", unit], timeout=10)[0] == 0


def health(c, was_active=None, island_from=None):
    checks = []
    if c == "halcyon":
        inst = installed(c)
        rec = read(os.path.join(HSTATE, "installed-commit"))
        checks.append(dict(name="version", ok=bool(inst["sha"]) and (not rec or rec == inst["sha"] or inst["source"] == "git"),
                           detail="at %s" % short(inst["sha"]) if inst["sha"] else "no commit recorded"))
        errs = island_errors(island_from if island_from is not None else max(0, island_size() - 20000))
        checks.append(dict(name="island log", ok=not errs, detail="no QML errors" if not errs else errs[0][:160]))
    elif c == "luna":
        p = os.path.join(BUILD_BIN, "luna")
        checks.append(binary_check(c, p))
        rc, _ = run([p, "--version"], timeout=8)
        if rc != 0:
            rc, _ = run([p, "--help"], timeout=8)
        checks.append(dict(name="runs", ok=(rc == 0), detail="answers --version" if rc == 0 else "does not start (exit %s)" % rc))
        for u in (was_active or []):
            checks.append(dict(name=u, ok=unit_active(u + ".service", True), detail="active" if unit_active(u + ".service", True) else "not running"))
    elif c == "ai-antivirus":
        checks.append(binary_check(c, AV_BIN))
        for s in (was_active if was_active is not None else ["engined", "sensord"]):
            ok = unit_active("ai-antivirus-%s.service" % s)
            checks.append(dict(name=s, ok=ok, detail="active" if ok else "not running"))
        rc, o = run(["ai-antivirus", "status", "--json"], timeout=10)
        if rc == 0:
            try:
                json.loads(o)
                checks.append(dict(name="status", ok=True, detail="ai-antivirus status answers"))
            except ValueError:
                checks.append(dict(name="status", ok=False, detail="ai-antivirus status printed no JSON"))
        else:
            checks.append(dict(name="status", ok=True, detail="status could not be read here (group ai-antivirus is applied at the next login)"))
    elif c == "ai-firewall":
        checks.append(binary_check(c, AIFW_BIN))
        rc, o = run(sudo_cmd([AIFW_BIN, "check"]) if os.geteuid() != 0 else [AIFW_BIN, "check"], timeout=30, env=dict(os.environ, **ENV_EXTRA))
        if rc != 0 and re.search(r"password is required|a terminal is required|no tty present", o):
            checks.append(dict(name="config", ok=True, detail="not checked: `ai-firewall check` needs the admin password"))
        else:
            checks.append(dict(name="config", ok=(rc == 0), detail="ai-firewall check passed" if rc == 0 else (o.strip().splitlines() or ["ai-firewall check failed"])[0][:160]))
        if was_active:
            ok = unit_active("ai-firewall.service")
            checks.append(dict(name="service", ok=ok, detail="active" if ok else "not running"))
            st = read("/run/ai-firewall/status.json")
            if st:
                try:
                    fresh = now() - int(json.loads(st).get("updated_unix", 0)) < 30
                    checks.append(dict(name="status", ok=fresh, detail="status file is fresh" if fresh else "status file is not updating"))
                except ValueError:
                    pass
    return dict(ok=all(x["ok"] for x in checks), checks=checks)


def cmd_health(a):
    c = need_comp(a.component)
    try:
        if c == "ai-firewall" and getattr(a, "password_stdin", False):
            prepare_root(c, a)
        jprint(health(c, active_units(c) if c != "halcyon" else None))
    finally:
        SUDO.cleanup()
    return 0


# ------------------------------------------------------------------ backups before a change
def backup_dir(c):
    return os.path.join(HSTATE, "backups", c)


def prune_backups(c, keep=3):
    d = backup_dir(c)
    if os.path.isdir(d):
        for old in sorted(os.listdir(d))[:-keep]:
            shutil.rmtree(os.path.join(d, old), ignore_errors=True)


def make_backup(c):
    """Copies what an older version might not read. Returns the folder (or None for Halcyon: install.sh makes its own backup)."""
    if c == "halcyon":
        return None
    dest = os.path.join(backup_dir(c), time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(dest, mode=0o700, exist_ok=True)
    os.chmod(dest, 0o700)
    if c == "luna":
        toml = os.path.join(HOME, ".config", "luna", "luna.toml")
        files = [toml, os.path.join(HOME, ".local", "share", "luna", "history.json"), os.path.join(HOME, ".local", "share", "luna", "conversations.jsonl"),
                 os.path.join(HOME, ".local", "share", "luna", "sessions.jsonl")]
        m = re.search(r'^\s*history_path\s*=\s*"([^"]+)"', read(toml), re.M)
        if m and os.path.expanduser(m.group(1)) not in files:
            files.append(os.path.expanduser(m.group(1)))
        n = 0
        for f in files:
            if os.path.isfile(f):
                shutil.copy2(f, os.path.join(dest, "%d-%s" % (n, os.path.basename(f))))
                write(os.path.join(dest, "%d-%s.path" % (n, os.path.basename(f))), f)
                n += 1
        say("LUNA: %d file(s) copied to %s" % (n, dest))
    elif c == "ai-antivirus":
        active = [s for s in AV_UNITS if unit_active("ai-antivirus-%s.service" % s)]
        if active:
            run(sudo_cmd(["systemctl", "stop"] + ["ai-antivirus-%s.service" % s for s in active]), timeout=60, env=dict(os.environ, **ENV_EXTRA))
        tarp = os.path.join(dest, "db.tar")
        with open(tarp, "wb") as out:
            p = subprocess.run(sudo_cmd(["tar", "-C", os.path.dirname(AV_DB_DIR.rstrip("/")), "-cpf", "-", os.path.basename(AV_DB_DIR.rstrip("/"))]),
                               stdout=out, stderr=subprocess.PIPE, env=dict(os.environ, **ENV_EXTRA), stdin=subprocess.DEVNULL, timeout=300)
        os.chmod(tarp, 0o600)
        if active:       # protection comes back at once; update-extras.sh restarts what is running when it installs
            run(sudo_cmd(["systemctl", "start"] + ["ai-antivirus-%s.service" % s for s in active]), timeout=60, env=dict(os.environ, **ENV_EXTRA))
        if p.returncode != 0 or os.path.getsize(tarp) == 0:
            shutil.rmtree(dest, ignore_errors=True)
            raise Fail("The %s backup could not be made (%s). Nothing was changed." % (AV_DB_DIR, (p.stderr or b"").decode("utf-8", "replace").strip()[:120]))
        say("ai-antivirus: %s copied to %s" % (AV_DB_DIR, tarp))
    elif c == "ai-firewall":
        tarp = os.path.join(dest, "etc.tar")
        with open(tarp, "wb") as out:
            p = subprocess.run(sudo_cmd(["tar", "-C", "/etc", "-cpf", "-", "ai-firewall"]), stdout=out, stderr=subprocess.PIPE,
                               env=dict(os.environ, **ENV_EXTRA), stdin=subprocess.DEVNULL, timeout=60)
        os.chmod(tarp, 0o600)
        if p.returncode != 0:      # no config folder yet is fine
            os.remove(tarp)
            say("ai-firewall: no /etc/ai-firewall to copy")
        else:
            say("ai-firewall: /etc/ai-firewall copied to %s" % tarp)
    prune_backups(c)
    return dest


def latest_backup(c):
    d = backup_dir(c)
    if not os.path.isdir(d):
        return None
    names = sorted(os.listdir(d))
    return os.path.join(d, names[-1]) if names else None


def restore_backup(c, folder=None):
    folder = folder or latest_backup(c)
    if not folder or not os.path.isdir(folder):
        raise Fail("There is no backup of %s to restore." % COMPONENTS[c]["name"])
    env = dict(os.environ, **ENV_EXTRA)
    if c == "luna":
        n = 0
        for f in sorted(os.listdir(folder)):
            if f.endswith(".path"):
                target = read(os.path.join(folder, f))
                srcf = os.path.join(folder, f[:-5])
                if target and os.path.isfile(srcf):
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copy2(srcf, target)
                    n += 1
        say("LUNA: %d file(s) put back" % n)
    elif c == "ai-antivirus":
        tarp = os.path.join(folder, "db.tar")
        if not os.path.isfile(tarp):
            raise Fail("The backup folder has no db.tar.")
        active = [s for s in AV_UNITS if unit_active("ai-antivirus-%s.service" % s)]
        if active:
            run(sudo_cmd(["systemctl", "stop"] + ["ai-antivirus-%s.service" % s for s in active]), timeout=60, env=env)
        with open(tarp, "rb") as inp:
            p = subprocess.run(sudo_cmd(["tar", "-C", os.path.dirname(AV_DB_DIR.rstrip("/")), "-xpf", "-"]), stdin=inp, stderr=subprocess.PIPE, env=env, timeout=300)
        if active:
            run(sudo_cmd(["systemctl", "start"] + ["ai-antivirus-%s.service" % s for s in active]), timeout=60, env=env)
        if p.returncode != 0:
            raise Fail("The database could not be put back: %s" % (p.stderr or b"").decode("utf-8", "replace").strip()[:120])
        say("ai-antivirus: %s put back from %s" % (AV_DB_DIR, tarp))
    elif c == "ai-firewall":
        tarp = os.path.join(folder, "etc.tar")
        if os.path.isfile(tarp):
            with open(tarp, "rb") as inp:
                p = subprocess.run(sudo_cmd(["tar", "-C", "/etc", "-xpf", "-"]), stdin=inp, stderr=subprocess.PIPE, env=env, timeout=60)
            if p.returncode != 0:
                raise Fail("The config could not be put back.")
            say("ai-firewall: /etc/ai-firewall put back")
    else:
        raise Fail("Halcyon's own backup is in ~/.config/Halcyon-backups (install.sh made it).")


def locked(fn):
    """One operation at a time. The caller gets exit 43 when another one runs."""
    def wrap(a):
        global LOG
        os.makedirs(HSTATE, exist_ok=True)
        fd = os.open(os.path.join(HSTATE, "versions.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            b = busy_info() or {}
            sys.stdout.write("##result " + json.dumps(dict(ok=False, error="Another operation is running (%s)." % (b.get("component", "?")), busy=True)) + "\n")
            return 43
        logp = os.path.join(HSTATE, "versions.log")
        if os.path.exists(logp) and os.path.getsize(logp) > 1 << 20:
            open(logp, "w").close()
        LOG = open(logp, "a", encoding="utf-8")
        LOG.write("\n=== %s halcyon-versions %s\n" % (time.strftime("%F %T"), " ".join(sys.argv[1:])))
        signal.signal(signal.SIGTERM, kill_child)
        signal.signal(signal.SIGINT, kill_child)
        try:
            return fn(a)
        except Fail as e:
            r = dict(ok=False, error=str(e))
            if e.needs:
                r["needs"] = e.needs
            sys.stdout.write("##result " + json.dumps(r) + "\n")
            return e.code
        finally:
            SUDO.cleanup()
            release_busy()
            LOG.close()
            LOG = None
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
    return wrap


def emit_result(r):
    say("##result " + json.dumps(r, ensure_ascii=False))


def cmd_backups(a):
    c = need_comp(a.component)
    d = backup_dir(c)
    items = []
    if os.path.isdir(d):
        for n in sorted(os.listdir(d), reverse=True):
            items.append(dict(path=os.path.join(d, n), name=n))
    jprint(dict(backups=items))
    return 0


@locked
def cmd_restore_backup(a):
    c = need_comp(a.component)
    prepare_root(c, a)
    step("Putting the copy of %s back" % COMPONENTS[c]["name"])
    restore_backup(c, a.folder)
    emit_result(dict(ok=True, component=c, op="restore-backup", changed=False))
    return 0


# ------------------------------------------------------------------ operations
def busy_begin(c, op):
    write(os.path.join(HSTATE, "versions.busy"), json.dumps(dict(component=c, op=op, started=now())))


def release_busy():
    try:
        os.remove(os.path.join(HSTATE, "versions.busy"))
    except OSError:
        pass


def active_units(c):
    if c == "luna":
        return [u for u in ("luna-daemon", "luna-wake") if unit_active(u + ".service", True)]
    if c == "ai-antivirus":
        return [s for s in AV_UNITS if unit_active("ai-antivirus-%s.service" % s)]
    if c == "ai-firewall":
        return ["ai-firewall"] if unit_active("ai-firewall.service") else []
    return []


def extras_cmd(c, ref=None, ignore_pins=False):
    cmd = ["bash", script(os.path.join("scripts", "update-extras.sh")), "--only", c, "--yes"]
    if ref:
        cmd += ["--ref", ref]
    if ignore_pins:
        cmd.append("--ignore-pins")
    return cmd


def do_install(c, ref, want_main, pinned_before):
    """Run the real script for one component. ref = a commit/tag (pins); want_main = move to main (explicit update; drops a pin)."""
    if c == "halcyon":
        cmd = ["bash", script("update.sh"), "--yes", "--no-extras"]
        if ref:
            cmd += ["--ref", ref]
        elif want_main and pinned_before:
            cmd += ["--unpin"]
        return stream(cmd)
    return stream(extras_cmd(c, ref=ref, ignore_pins=(want_main and not ref)))


def op_one(c, kind, ref=None, a=None, quiet_result=False):
    """update | install-version | rollback for one component, with backups, a health check and an automatic way back."""
    d = COMPONENTS[c]
    inst0 = installed(c)
    st = component_status(c)
    before = inst0["sha"]
    pin_before = pins().get(d["key"], "")
    res = dict(component=c, name=d["name"], op=kind, ok=False, changed=False, restored=False, error=None, **{"from": before})
    if st["managed"] == "pacman":
        res["error"] = "ai-firewall came from a pacman package: pacman keeps it updated."
        return res
    if not chosen(c) and not inst0["present"]:
        # a component not installed yet: the installer does it (the same ./install.sh --luna ... a terminal would run), then the version asked for
        if kind == "install-version" or kind == "update":
            step("Installing %s (install.sh)" % d["name"])
            rc = stream(["bash", script("install.sh"), "--yes"] + INSTALL_FLAG[c])
            res["ok"] = rc == 0 and installed(c)["present"]
            res["error"] = None if res["ok"] else "install.sh did not finish %s (see the log)" % d["name"]
            res["changed"] = res["ok"]
            res["to"] = installed(c)["sha"]
            if res["ok"] and kind == "install-version" and ref:
                return op_one(c, "install-version", ref, a)
            return res
    if kind == "rollback":
        ref = previous_version(c)
        if not ref:
            res["error"] = "There is no earlier version recorded for %s." % d["name"]
            return res
        if ref == before:
            res["error"] = "Already at the earlier version."
            return res
        fast = c != "halcyon" and os.path.isfile(os.path.join(HSTATE, "prev", c, "stamp"))
    else:
        fast = False
    target = None
    if ref:
        target = resolve(c, ref) or (ref if is_sha(ref) else None)
        if not target:
            res["error"] = "%s is not a commit or tag of %s (press Check now to load the history)." % (ref, d["name"])
            return res
    island_from = island_size()
    was = active_units(c)
    older = False
    if target and before and in_cache(c, before):
        older = git(cache_repo(c), "merge-base", "--is-ancestor", target, before)[0] == 0 and target != before
    # ---- the password, the backup
    prepare_root(c, a)
    backup = None
    if kind != "update" or (before and before != (resolve(c, "HEAD") or before)):
        if c != "halcyon":
            step("Backing up (%s)" % d["name"])
            backup = make_backup(c)
            res["backup"] = backup
    # ---- the change
    step("%s %s" % ({"update": "Updating", "install-version": "Installing a version of", "rollback": "Rolling back"}[kind], d["name"]))
    if fast:
        rc = stream(["bash", script(os.path.join("scripts", "update-extras.sh")), "--only", c, "--restore", c])
        if rc == 0:
            pin_set(c, previous_version(c))
    elif kind == "update":
        rc = do_install(c, None, True, pin_before)
    else:
        rc = do_install(c, ref if kind == "install-version" else target, False, pin_before)
    after = installed(c)["sha"]
    res["to"] = after
    res["changed"] = after != before
    res["older"] = older
    expect = target if (kind != "update") else None
    ok = rc == 0 and (expect is None or after == expect or (c != "halcyon" and installed(c)["stamp"].startswith(expect)))
    if not ok:
        res["error"] = "The new version did not install: %s stays." % ("the version you had" if after == before else "a version that is not the one asked for")
        if pin_before:
            pin_set(c, pin_before)
        else:
            pin_del(c)
        res["health"] = health(c, [u for u in was] if c != "halcyon" else None, island_from)
        return finish_res(res)
    # ---- the health check, and the way back
    if res["changed"] or kind != "update":
        step("Checking that %s works" % d["name"])
        res["health"] = health(c, was if c != "halcyon" else None, island_from)
        if not res["health"]["ok"] and before and c != "halcyon":
            bad = [x["detail"] for x in res["health"]["checks"] if not x["ok"]]
            say("! the health check failed (%s): putting the version you had back" % "; ".join(bad))
            step("Restoring the earlier version")
            rrc = stream(["bash", script(os.path.join("scripts", "update-extras.sh")), "--only", c, "--restore", c])
            if rrc != 0:
                rrc = stream(extras_cmd(c, ref=before))
            if c == "ai-antivirus" and backup:
                try:
                    restore_backup(c, backup)
                except Fail as e:
                    say("! the database copy could not be put back: %s" % e)
            if pin_before:
                pin_set(c, pin_before)
            else:
                pin_del(c)
            res["restored"] = rrc == 0 and installed(c)["sha"] == before
            res["ok"] = False
            res["error"] = "The new version failed its health check (%s). %s" % ("; ".join(bad), "The version you had is back." if res["restored"] else "Putting the old one back failed too: see the log.")
            res["health_after"] = health(c, was, island_from)
            return finish_res(res)
        if not res["health"]["ok"]:
            res["error"] = "The island printed errors with this version. Use Roll back to return."
    res["ok"] = True
    return finish_res(res)


def finish_res(res):
    if res.get("ok") and res["op"] == "install-version" and res.get("to"):
        c = [k for k, v in COMPONENTS.items() if v["name"] == res["name"]][0]
        pin_set(c, res["to"])
    return res


def previous_version(c):
    if c == "halcyon":
        p = read(os.path.join(HSTATE, "previous-commit"))
        return p if is_sha(p) else None
    s = read(os.path.join(HSTATE, "prev", c, "stamp")).split("-")[0]
    return s if is_sha(s) else None


def enforce_pins_after_halcyon(snapshot, a):
    """An older install.sh does not know about pins and may have moved a pinned extra to main: put it back."""
    for c in ("luna", "ai-firewall", "ai-antivirus"):
        pin = pins().get(COMPONENTS[c]["key"])
        if pin and snapshot.get(c) and installed(c)["sha"] != pin and installed(c)["sha"] != snapshot[c]:
            step("%s was moved by the Halcyon setup: putting it back at %s" % (COMPONENTS[c]["name"], short(pin)))
            stream(extras_cmd(c, ref=pin))


@locked
def cmd_update(a):
    target = a.component
    if target != "all":
        need_comp(target)
    if target == "all" and a.ref:
        raise Fail("--ref needs one component", 2)
    comps = UPDATE_ORDER if target == "all" else [target]
    results = []
    snapshot = {c: installed(c)["sha"] for c in COMPONENTS}
    # one password for the whole run
    for c in comps:
        if target == "all" and (not chosen(c) or pins().get(COMPONENTS[c]["key"]) or not installed(c)["present"]):
            continue
        if COMPONENTS[c]["root"]:
            prepare_root(c, a)
            break
    for c in comps:
        if target == "all":
            if c != "halcyon" and not chosen(c):
                results.append(dict(component=c, name=COMPONENTS[c]["name"], ok=True, skipped="not installed", changed=False))
                continue
            if pins().get(COMPONENTS[c]["key"]):
                results.append(dict(component=c, name=COMPONENTS[c]["name"], ok=True, skipped="pinned", changed=False))
                step("%s is pinned: skipped" % COMPONENTS[c]["name"])
                continue
        busy_begin(c, "update")
        kind = "install-version" if a.ref else "update"
        r = op_one(c, kind, a.ref, a)
        results.append(r)
        if c == "halcyon" and r.get("changed"):
            enforce_pins_after_halcyon(snapshot, a)
    ok = all(r.get("ok") for r in results)
    emit_result(results[0] if len(results) == 1 else dict(ok=ok, results=results, op="update-all"))
    return 0 if ok else 1


@locked
def cmd_install_version(a):
    c = need_comp(a.component)
    snapshot = {k: installed(k)["sha"] for k in COMPONENTS}
    busy_begin(c, "install-version")
    r = op_one(c, "install-version", a.ref, a)
    if c == "halcyon" and r.get("changed"):
        enforce_pins_after_halcyon(snapshot, a)
    emit_result(r)
    return 0 if r.get("ok") else 1


@locked
def cmd_rollback(a):
    c = need_comp(a.component)
    busy_begin(c, "rollback")
    r = op_one(c, "rollback", None, a)
    if r.get("ok") and c == "halcyon" and r.get("to"):
        pin_set(c, r["to"])
    emit_result(r)
    return 0 if r.get("ok") else 1


@locked
def cmd_pin(a):
    c = need_comp(a.component)
    sha = installed(c)["sha"]
    if not sha:
        raise Fail("%s has no recorded version to pin." % COMPONENTS[c]["name"])
    pin_set(c, sha)
    emit_result(dict(ok=True, component=c, op="pin", pinned=sha))
    return 0


@locked
def cmd_unpin(a):
    c = need_comp(a.component)
    if a.no_update and c != "halcyon":
        pin_del(c)
        emit_result(dict(ok=True, component=c, op="unpin", changed=False))
        return 0
    busy_begin(c, "unpin")
    r = op_one(c, "update", None, a)
    r["op"] = "unpin"
    if r.get("ok"):
        pin_del(c)
    emit_result(r)
    return 0 if r.get("ok") else 1


# ------------------------------------------------------------------ the optional daily look
TIMER = "halcyon-versions-check.timer"
DOT = os.path.join(CACHE, "available.json")


def autocheck_state():
    rc, o = run(["systemctl", "--user", "is-enabled", TIMER], timeout=8)
    return rc == 0 and o.strip() == "enabled"


def cmd_autocheck(a):
    if a.mode == "status":
        jprint(dict(enabled=autocheck_state(), available=json.loads(read(DOT) or "{}")))
        return 0
    if a.mode in ("on", "off"):
        rc, o = run(["systemctl", "--user", "enable" if a.mode == "on" else "disable", "--now", TIMER], timeout=30)
        if a.mode == "off" and rc == 0:
            try:
                os.remove(DOT)
            except OSError:
                pass
        jprint(dict(ok=(rc == 0), enabled=autocheck_state(), error=None if rc == 0 else o.strip()[:200]))
        return 0 if rc == 0 else 1
    # run: look at GitHub, remember what is behind (the island shows a dot); install nothing, and not more than once a day
    last = max([cache_state().get(c, {}).get("checked", 0) for c in DISPLAY_ORDER] + [0])
    if not a.force and now() - last < 20 * 3600 and os.path.exists(DOT):
        jprint(dict(ok=True, skipped="checked less than a day ago"))
        return 0
    behind = {}
    for c in DISPLAY_ORDER:
        if c == "halcyon" or chosen(c) or installed(c)["present"]:
            refresh_cache(c)
            st = component_status(c)
            if st["state"] == "behind" and not st["pinned"]:
                behind[c] = st["behind"]
    write(DOT, json.dumps(dict(checked=now(), behind=behind)))
    jprint(dict(ok=True, behind=behind))
    return 0


# ------------------------------------------------------------------ main
def main(argv=None):
    ap = argparse.ArgumentParser(prog="halcyon-versions", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, fn, *args, **opts):
        p = sub.add_parser(name)
        for x in args:
            p.add_argument(x)
        if opts.get("pw"):
            p.add_argument("--password-stdin", action="store_true")
        p.add_argument("--yes", "-y", action="store_true")
        p.set_defaults(fn=fn)
        return p

    p = add("status", cmd_status)
    p.add_argument("--refresh", action="store_true")
    p = add("log", cmd_log, "component")
    p.add_argument("--from", dest="frm", type=int, default=0)
    p.add_argument("--limit", type=int, default=PAGE)
    add("tags", cmd_tags, "component")
    add("plan", cmd_plan, "component", "ref")
    p = add("update", cmd_update, "component", pw=True)
    p.add_argument("--ref")
    add("install-version", cmd_install_version, "component", "ref", pw=True)
    add("rollback", cmd_rollback, "component", pw=True)
    add("pin", cmd_pin, "component")
    p = add("unpin", cmd_unpin, "component", pw=True)
    p.add_argument("--no-update", action="store_true")
    add("health", cmd_health, "component", pw=True)
    add("backups", cmd_backups, "component")
    p = add("restore-backup", cmd_restore_backup, "component", pw=True)
    p.add_argument("folder", nargs="?")
    p = add("autocheck", cmd_autocheck)
    p.add_argument("mode", choices=["on", "off", "status", "run"])
    p.add_argument("--force", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if os.geteuid() == 0:
        sys.stderr.write("run this as your normal user, not root\n")
        return 1
    try:
        return a.fn(a)
    except Fail as e:
        r = dict(ok=False, error=str(e))
        if e.needs:
            r["needs"] = e.needs
        sys.stdout.write(json.dumps(r) + "\n")
        return e.code
    finally:
        SUDO.cleanup()


if __name__ == "__main__":
    sys.exit(main())
