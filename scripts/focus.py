#!/usr/bin/env python3
"""Halcyon focus mode: an advanced do-not-disturb for studying / work.

  focus.sh start [MINUTES] [pomo]   start a session (no MINUTES = the saved length)
  focus.sh stop | toggle            end it (everything goes back to how it was)
  focus.sh pause | resume           lift the app block for a moment, timer stands still
  focus.sh add MINUTES              make the running phase longer
  focus.sh skip                     end the running phase now (Pomodoro: go to the break / next round)
  focus.sh status                   JSON for the island (also tidies up after a crashed session)
  focus.sh conf                     JSON: saved options + the blocked apps list
  focus.sh set KEY VALUE            save an option (LENGTH POMODORO BREAK LONG_BREAK CYCLES DND CAFFEINE BLOCK CLOSE_RUNNING BREAK_FREE)
  focus.sh apps                     JSON: blocked apps + the windows that are open right now
  focus.sh block CLASS [CLASS...] | unblock CLASS

While a session runs (a tiny background process, the transient user unit halcyon-focus.service):
  * Do not disturb is on (urgent notifications still get through), Caffeine is on (no dim / lock / sleep)
  * windows of the apps in ~/.config/Halcyon/focus-apps.conf are closed the moment they open (a normal close request,
    never a kill, so an app can still ask about unsaved work) and the ones already open are closed when the session starts
  * Pomodoro: work / short break / ... / long break. The block is lifted in breaks (BREAK_FREE=0 keeps it)
  * when it ends, Do not disturb and Caffeine go back to what they were before (one you had switched on yourself stays on)
Window classes: `hyprctl clients` shows them; one per line in focus-apps.conf, * works as a wildcard, case does not matter.
"""
import fnmatch
import json
import os
import re
import select
import signal
import socket
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
RT = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
STATE = os.path.join(RT, "halcyon-focus.json")                      # the live session (gone at logout)
MARKER = os.path.join(HOME, ".local/state/island/focus-restore.json")  # what to put back if a session dies without cleaning up
CONF = os.path.join(HOME, ".config/Halcyon/focus.conf")
APPS = os.path.join(HOME, ".config/Halcyon/focus-apps.conf")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ISLAND = os.path.join(HOME, ".config/Halcyon/quickshell/island")
SETTINGS = os.path.join(HOME, ".local/state/island/settings.json")
UNIT = "halcyon-focus"

DEFAULTS = {"LENGTH": 25, "POMODORO": 0, "BREAK": 5, "LONG_BREAK": 15, "CYCLES": 4,
            "DND": 1, "CAFFEINE": 1, "BLOCK": 1, "CLOSE_RUNNING": 1, "BREAK_FREE": 1}
LIMITS = {"LENGTH": (1, 480), "BREAK": (1, 60), "LONG_BREAK": (1, 120), "CYCLES": (1, 12)}
FLAGS = ("POMODORO", "DND", "CAFFEINE", "BLOCK", "CLOSE_RUNNING", "BREAK_FREE")
CLASS_OK = re.compile(r"^[A-Za-z0-9_.\-+*]{1,80}$")


# ------------------------------------------------------------------ small helpers
def run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def island(*args):
    run(["quickshell", "ipc", "-p", ISLAND, "call", "island"] + list(args), 4)


def notify(title, body, critical=False, icon="appointment-soon"):
    cmd = ["notify-send", "-a", "Halcyon", "-i", icon, "-t", "6000"]
    if critical:
        cmd += ["-u", "critical"]      # critical ones are the only popups Do not disturb lets through
    run(cmd + [title, body], 3)


def chime():
    for f in ("/usr/share/sounds/freedesktop/stereo/complete.oga", "/usr/share/sounds/freedesktop/stereo/message.oga"):
        if os.path.exists(f):
            for player in (["paplay", f], ["pw-play", f]):
                try:
                    subprocess.Popen(player, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    return
                except Exception:
                    continue
            return


def caffeine(*args):
    r = run(["bash", os.path.join(SCRIPTS, "caffeine.sh")] + list(args), 6)
    return (r.stdout or "").strip() if r else ""


def dnd_is_on():
    try:
        with open(SETTINGS) as f:
            return bool(json.load(f).get("dnd"))
    except Exception:
        return False


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


# ------------------------------------------------------------------ saved options + blocked apps
def load_conf():
    c = dict(DEFAULTS)
    try:
        with open(CONF) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k in c:
                    c[k] = clean(k, v, c[k])
    except OSError:
        pass
    return c


def clean(k, v, fallback):
    v = str(v).strip().lower()
    if k in FLAGS:
        return 1 if v in ("1", "true", "on", "yes") else (0 if v in ("0", "false", "off", "no") else fallback)
    try:
        lo, hi = LIMITS[k]
        return max(lo, min(hi, int(float(v))))
    except Exception:
        return fallback


def save_conf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    tmp = CONF + ".tmp"
    with open(tmp, "w") as f:
        for k in DEFAULTS:
            f.write("%s=%s\n" % (k, c[k]))
    os.replace(tmp, CONF)


def blocked_list():
    out = []
    try:
        with open(APPS) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line and CLASS_OK.match(line) and line.lower() not in [x.lower() for x in out]:
                    out.append(line)
    except OSError:
        pass
    return out


def save_blocked(items):
    os.makedirs(os.path.dirname(APPS), exist_ok=True)
    tmp = APPS + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Window classes Focus mode closes while a session runs: one per line, * is a wildcard, case does not matter.\n")
        f.write("# Find a class with:  hyprctl clients | grep class      (or add it from Settings > Focus)\n")
        for x in items:
            f.write(x + "\n")
    os.replace(tmp, APPS)


def matches(patterns, *names):
    for n in names:
        n = (n or "").lower()
        if not n:
            continue
        for p in patterns:
            if fnmatch.fnmatchcase(n, p.lower()):
                return True
    return False


# ------------------------------------------------------------------ Hyprland
def clients():
    r = run(["hyprctl", "-j", "clients"], 4)
    try:
        return json.loads(r.stdout) if r and r.returncode == 0 else []
    except Exception:
        return []


def close_window(addr):
    r = run(["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "address:%s" })' % addr], 4)
    if not r or r.stdout.strip() != "ok":                       # an older Hyprland without the Lua dispatchers
        run(["hyprctl", "dispatch", "closewindow", "address:" + addr], 4)


def hypr_socket():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    paths = []
    if sig:
        paths.append("%s/hypr/%s/.socket2.sock" % (RT, sig))
    try:
        base = os.path.join(RT, "hypr")
        paths += sorted((os.path.join(base, d, ".socket2.sock") for d in os.listdir(base)),
                        key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True)
    except OSError:
        pass
    for p in paths:
        if os.path.exists(p):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(p)
                s.setblocking(False)
                return s
            except OSError:
                continue
    return None


# ------------------------------------------------------------------ session state
def alive(st):
    pid = st.get("pid")
    if not pid:
        return time.time() - st.get("t0", 0) < 8          # the helper is still starting
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def live():
    st = read_json(STATE)
    if st and st.get("on") and alive(st):
        return st
    if st and st.get("on"):                                # the helper died: put everything back
        finish(st, False, quiet=True)
    return None


def reap_stale():
    """A session that died with the machine (logout, crash): its Do not disturb / Caffeine are still on."""
    if read_json(STATE):
        return
    m = read_json(MARKER)
    if m:
        restore(m)
        try:
            os.remove(MARKER)
        except OSError:
            pass


def restore(m):
    if m.get("caf") and not m.get("prev_caf"):
        caffeine("off")
    if m.get("dnd") and not m.get("prev_dnd"):
        island("dndset", "false")


def finish(st, completed, quiet=False):
    restore({"dnd": st.get("dnd"), "prev_dnd": st.get("prev", {}).get("dnd"),
             "caf": st.get("caf"), "prev_caf": st.get("prev", {}).get("caf")})
    for p in (STATE, MARKER):
        try:
            os.remove(p)
        except OSError:
            pass
    if not quiet:
        if completed:
            chime()
            notify("Focus session complete", "%d min focused%s. Do not disturb is off again."
                   % (st.get("done_min", st.get("mins", 0)),
                      (", %d apps kept out" % st["closed"]) if st.get("closed") else ""),
                   icon="emblem-ok-symbolic")
        else:
            notify("Focus stopped", "Everything is back to normal.", icon="emblem-ok-symbolic")


def public(st):
    now = time.time()
    left = st["left"] if st.get("paused") else max(0, int(round(st["end"] - now)))
    return {"on": True, "phase": st["phase"], "paused": bool(st.get("paused")), "left": left,
            "end": st["end"], "total": st["total"], "cycle": st["cycle"], "cycles": st["cycles"],
            "pomodoro": bool(st.get("pomodoro")), "mins": st["mins"], "closed": st.get("closed", 0),
            "blocking": blocking_now(st, load_conf())}


def blocking_now(st, conf):
    if not conf["BLOCK"] or st.get("paused"):
        return False
    return st["phase"] == "work" or not conf["BREAK_FREE"]


# ------------------------------------------------------------------ commands
def cmd_start(args):
    reap_stale()
    if live():
        print("already running")
        return 1
    conf = load_conf()
    mins = conf["LENGTH"]
    pomo = bool(conf["POMODORO"])
    for a in args:
        a = a.lower()
        if a.isdigit():
            mins = clean("LENGTH", a, mins)
        elif a in ("1", "pomo", "pomodoro", "true", "on"):
            pomo = True
        elif a in ("0", "single", "nopomo", "false", "off"):
            pomo = False
    prev = {"dnd": dnd_is_on(), "caf": caffeine("status") == "on"}
    now = time.time()
    st = {"on": True, "phase": "work", "paused": False, "t0": now, "start": now, "end": now + mins * 60,
          "left": mins * 60, "total": mins * 60, "cycle": 1, "cycles": conf["CYCLES"] if pomo else 1,
          "pomodoro": pomo, "mins": mins, "done_min": 0, "prev": prev, "closed": 0,
          "dnd": bool(conf["DND"]), "caf": bool(conf["CAFFEINE"])}
    write_json(STATE, st)
    write_json(MARKER, {"dnd": st["dnd"], "prev_dnd": prev["dnd"], "caf": st["caf"], "prev_caf": prev["caf"]})
    if st["dnd"]:
        island("dndset", "true")
    if st["caf"] and not prev["caf"]:
        caffeine("on")
    start_daemon()
    return 0


def start_daemon():
    run(["systemctl", "--user", "stop", UNIT + ".service"], 4)
    keys = ("HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
            "XDG_CURRENT_DESKTOP", "DISPLAY")
    cmd = ["systemd-run", "--user", "--quiet", "--collect", "--unit=" + UNIT]
    cmd += ["--setenv=%s=%s" % (k, os.environ[k]) for k in keys if k in os.environ]
    cmd += [sys.executable, os.path.abspath(__file__), "daemon"]
    r = run(cmd, 6)
    if r and r.returncode == 0:
        return
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "daemon"], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cmd_stop(_args=None):
    st = read_json(STATE)
    if st and st.get("on"):
        spent = st.get("done_min", 0)
        if st["phase"] == "work":
            left = st["left"] if st.get("paused") else max(0, st["end"] - time.time())
            spent += max(0, st["total"] - left) / 60
        st["done_min"] = int(spent)
        finish(st, False)
    else:
        reap_stale()
    run(["systemctl", "--user", "stop", UNIT + ".service"], 4)
    return 0


def edit(fn):
    st = live()
    if not st:
        print("no session")
        return 1
    fn(st)
    write_json(STATE, st)
    return 0


def cmd_pause(_a=None):
    def f(st):
        if not st["paused"]:
            st["left"] = max(1, int(st["end"] - time.time()))
            st["paused"] = True
    return edit(f)


def cmd_resume(_a=None):
    def f(st):
        if st["paused"]:
            st["end"] = time.time() + st["left"]
            st["paused"] = False
            st["sweep"] = True          # apps opened during the pause get closed again
    return edit(f)


def cmd_add(args):
    mins = int(args[0]) if args and args[0].lstrip("-").isdigit() else 5

    def f(st):
        if st["paused"]:
            st["left"] = max(30, st["left"] + mins * 60)
        else:
            st["end"] = max(time.time() + 30, st["end"] + mins * 60)
        st["total"] = max(60, st["total"] + mins * 60)
    return edit(f)


def cmd_skip(_a=None):
    def f(st):
        st["end"] = time.time()
        st["paused"] = False
    return edit(f)


def cmd_toggle(args):
    return cmd_stop() if live() else cmd_start(args)


def cmd_status(_a=None):
    reap_stale()
    st = live()
    print(json.dumps(public(st) if st else {"on": False}))
    return 0


def conf_json():
    c = load_conf()
    out = {k: (bool(v) if k in FLAGS else v) for k, v in c.items()}
    out["apps"] = blocked_list()
    return out


def cmd_conf(_a=None):
    print(json.dumps(conf_json()))
    return 0


def cmd_set(args):
    if len(args) < 2 or args[0] not in DEFAULTS:
        print("usage: focus.sh set KEY VALUE")
        return 2
    c = load_conf()
    c[args[0]] = clean(args[0], args[1], c[args[0]])
    save_conf(c)
    return 0


def cmd_apps(_a=None):
    blocked = blocked_list()
    seen, opened = set(), []
    for c in clients():
        cls = c.get("class") or c.get("initialClass") or ""
        if not cls or cls.lower() in seen or "quickshell" in cls.lower() or not CLASS_OK.match(cls):
            continue
        seen.add(cls.lower())
        opened.append({"class": cls, "title": (c.get("title") or "")[:60], "blocked": matches(blocked, cls)})
    print(json.dumps({"blocked": blocked, "open": sorted(opened, key=lambda x: x["class"].lower())}))
    return 0


def cmd_block(args):
    # one or more classes (Settings sends an app's class plus its program name in ONE call: the list is read-modify-written once)
    good = [a for a in args if CLASS_OK.match(a)]
    if not good:
        print("not a window class")
        return 2
    items = blocked_list()
    have = [x.lower() for x in items]
    changed = False
    for a in good:
        if a.lower() not in have:
            items.append(a)
            have.append(a.lower())
            changed = True
    if changed:
        save_blocked(items)
    return 0


def cmd_unblock(args):
    if not args:
        return 2
    save_blocked([x for x in blocked_list() if x.lower() != args[0].lower()])
    return 0


# ------------------------------------------------------------------ the helper process
class Blocker:
    def __init__(self):
        self.last = {}            # class -> when we last told you
        self.asked = {}           # address -> [count, when]
        self.spare = set()        # windows that were already open when the block began (CLOSE_RUNNING = 0)

    def check(self, st, addr, cls, init_cls=""):
        patterns = blocked_list()
        if not patterns or addr in self.spare or not matches(patterns, cls, init_cls):
            return False
        n, t = self.asked.get(addr, [0, 0])
        if n >= 3 or time.time() - t < 4:
            return True
        self.asked[addr] = [n + 1, time.time()]
        close_window(addr)
        if n == 0:
            st["closed"] = st.get("closed", 0) + 1
            write_json(STATE, st)
            if time.time() - self.last.get(cls.lower(), 0) > 20:
                self.last[cls.lower()] = time.time()
                notify("Focus", "%s was closed. Focus ends in %d min." % (cls, max(1, int((st["end"] - time.time()) / 60))),
                       icon="dialog-information")
        return True

    def sweep(self, st):
        patterns = blocked_list()
        if not patterns:
            return
        for c in clients():
            if c.get("mapped", True):
                self.check(st, c.get("address", ""), c.get("class", ""), c.get("initialClass", ""))


def next_phase(st, conf):
    """The running phase is over: returns True when the whole session is over."""
    now = time.time()
    if st["phase"] == "work":
        st["done_min"] = st.get("done_min", 0) + st["mins"]
        if not st["pomodoro"]:
            return True
        long = st["cycle"] >= st["cycles"]
        mins = conf["LONG_BREAK"] if long else conf["BREAK"]
        st.update(phase="long" if long else "break", start=now, end=now + mins * 60, total=mins * 60, left=mins * 60)
        chime()
        notify("Break time" if not long else "Last round done",
               "%d min off%s." % (mins, "" if conf["BREAK_FREE"] else " (apps stay blocked)"), critical=True, icon="appointment-soon")
        return False
    if st["phase"] == "long":
        return True
    st.update(phase="work", cycle=st["cycle"] + 1, start=now, end=now + st["mins"] * 60, total=st["mins"] * 60, left=st["mins"] * 60)
    st["sweep"] = True
    chime()
    notify("Back to focus", "Round %d of %d, %d min." % (st["cycle"], st["cycles"], st["mins"]), critical=True, icon="appointment-soon")
    return False


def daemon():
    st = read_json(STATE)
    if not st or not st.get("on"):
        return 0
    st["pid"] = os.getpid()
    write_json(STATE, st)

    def bye(*_):
        # `focus.sh stop` has already put everything back. At logout the island is gone too, so nothing is touched here:
        # the restore marker stays, and the next status / start (or the next login) puts Do not disturb / Caffeine back
        sys.exit(0)
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    blocker = Blocker()
    sock = hypr_socket()
    buf = b""
    last_sweep = 0.0
    last_conf = 0.0
    conf = load_conf()
    was_blocking = False
    while True:
        st = read_json(STATE)
        if not st or not st.get("on"):
            return 0
        if st.get("pid") != os.getpid():            # another helper took over
            return 0
        now = time.time()
        if now - last_conf > 5:
            conf, last_conf = load_conf(), now
        if not st["paused"] and now >= st["end"]:
            if next_phase(st, conf):
                finish(st, True)
                return 0
            write_json(STATE, st)
        active = blocking_now(st, conf)
        if active:
            if not was_blocking and not conf["CLOSE_RUNNING"]:
                blocker.spare = {c.get("address", "") for c in clients()}
            if not was_blocking or st.get("sweep") or now - last_sweep > 3:     # the 3 s sweep catches windows that name their class late
                blocker.sweep(st)
                last_sweep = now
                if st.pop("sweep", None):
                    write_json(STATE, st)
        was_blocking = active

        if sock is None:
            time.sleep(1.0)
            if int(now) % 10 == 0:
                sock = hypr_socket()
            continue
        r, _, _ = select.select([sock], [], [], 1.0)
        if not r:
            continue
        try:
            data = sock.recv(65536)
        except (BlockingIOError, InterruptedError):
            continue
        except OSError:
            data = b""
        if not data:
            sock = None
            continue
        buf += data
        lines = buf.split(b"\n")
        buf = lines.pop()
        for raw in lines:
            if not active or not raw.startswith(b"openwindow>>"):
                continue
            parts = raw.decode("utf-8", "replace")[len("openwindow>>"):].split(",", 3)
            if len(parts) >= 3:
                blocker.check(st, "0x" + parts[0], parts[2])


COMMANDS = {"start": cmd_start, "stop": cmd_stop, "toggle": cmd_toggle, "pause": cmd_pause, "resume": cmd_resume,
            "add": cmd_add, "skip": cmd_skip, "status": cmd_status, "conf": cmd_conf, "set": cmd_set,
            "apps": cmd_apps, "block": cmd_block, "unblock": cmd_unblock}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(__doc__)
        sys.exit(0)
    if sys.argv[1] == "daemon":
        sys.exit(daemon() or 0)
    fn = COMMANDS.get(sys.argv[1])
    if not fn:
        print("unknown command: " + sys.argv[1])
        sys.exit(2)
    sys.exit(fn(sys.argv[2:]) or 0)
