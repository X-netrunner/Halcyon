#!/usr/bin/env python3
"""halcyon-fx.py: Safe mode and Profiles for the Halcyon island.

  halcyon safe-mode [on|off|back|toggle|status]
        on (default)   switch off blur, shadows, window animations, stars, island motion and the other heavy effects, then reload the
                       island. Your current values are saved first (state/safe-mode.json).
        off | back     "Back to normal": put the saved values back and reload.
        toggle         on when it is off, back when it is on (this is what the shortcut runs)
        status         say whether safe mode is on

  halcyon profile [list|status|work|gaming|battery|night|custom]
        One switch for stars, blur, motion, screen brightness and the top bar. The first time you leave "custom" your own values are
        saved (state/profile.json); "custom" puts them back.

  Plain files, no daemon: this only edits ~/.local/state/island/settings.json (the file the island reads at start), pushes the
  Hyprland effects directly, and asks the island to reload. It works from a terminal or a TTY (it finds the Hyprland session
  by itself), also when the island is not running or does not answer.

  Profile values can be changed in ~/.local/state/island/profiles.json, for example
      { "battery": { "brightness": 30 }, "work": { "stars": true } }
  Fields: stars (true/false), blur (true/false), motion (0 off, 0.5 fast, 1 normal), brightness (percent, or null = leave),
  bar ("on", "off" or null = leave).

Options: --no-reload (change the files only), --json (status as JSON).
Exit status: 0 done, 1 failed, 2 usage, 3 refused (safe mode is on).
"""
import json
import os
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR") or os.path.join(HOME, ".config", "Halcyon")
STATE = os.environ.get("HALCYON_STATE") or os.path.join(HOME, ".local", "state", "island")
SETTINGS = os.path.join(STATE, "settings.json")
SAFE_FILE = os.path.join(STATE, "safe-mode.json")
PROFILE_FILE = os.path.join(STATE, "profile.json")
OVERRIDES = os.path.join(STATE, "profiles.json")
ISLAND_DIR = os.path.join(RICE, "quickshell", "island")

# ------------------------------------------------------------------------------------------------ what safe mode sets
# (top = the keys at the top of settings.json, opt = under "opt", hy = under "hy"). Only effects: the bar, the launcher, the
# lock screen's password box and every setting that is not listed here are never touched.
SAFE = {
    "top": {"blur": False, "shadows": False, "hyprAnim": False, "motion": 0, "profileStars": False, "hyprTouched": True},
    "opt": {"stars": False, "starsBar": False, "dialogStarStyle": "none", "perf": "low", "fps": 30, "viz": "off",
            "accentMode": "fixed", "termDrift": False, "lazyLoad": True, "lockBg": "solid", "treeConst": "off", "treeDots": "off"},
    "hy": {"blurSize": 1, "blurPasses": 1},
}

# ------------------------------------------------------------------------------------------------ profiles
PROFILES = {
    "work":    {"stars": False, "blur": True,  "motion": 0.5, "brightness": None, "bar": "on"},
    "gaming":  {"stars": False, "blur": False, "motion": 0,   "brightness": None, "bar": "off"},
    "battery": {"stars": False, "blur": False, "motion": 0.5, "brightness": 40,   "bar": "on"},
    "night":   {"stars": True,  "blur": True,  "motion": 1,   "brightness": 15,   "bar": "on"},
}
PROFILE_LABELS = {"work": "Work", "gaming": "Gaming", "battery": "Battery", "night": "Night", "custom": "Custom"}
# every key any profile can change: these are what "custom" saves and puts back
PROFILE_KEYS = {"top": ["blur", "motion", "profileStars", "hyprTouched"], "opt": ["stars", "starsBar", "barStyle"], "hy": []}


def say(msg):
    print(msg)


def err(msg):
    print("halcyon: " + msg, file=sys.stderr)


# ------------------------------------------------------------------------------------------------ files
def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except (ValueError, OSError):
        return default


def write_json(path, data, pretty=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp-%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        if pretty:
            json.dump(data, f, indent=2, ensure_ascii=False)
        else:
            json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)          # the island never sees half a file


def load_settings():
    """settings.json as a dict. A missing file is {}. A file that is not valid JSON is moved aside (never lost) and {} is used."""
    try:
        with open(SETTINGS, "r", encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return {}
    if raw.strip() == "":
        return {}
    try:
        s = json.loads(raw)
        if isinstance(s, dict):
            return s
    except ValueError:
        pass
    bad = SETTINGS + ".bad-" + time.strftime("%Y%m%d-%H%M%S")
    try:
        os.replace(SETTINGS, bad)
        err("settings.json was not valid JSON; it was kept as " + bad + " and fresh settings are used")
    except OSError:
        pass
    return {}


def section(s, name):
    if name == "top":
        return s
    if not isinstance(s.get(name), dict):
        s[name] = {}
    return s[name]


def snapshot(s, keys):
    """The current value of every listed key, and which of them did not exist at all."""
    snap = {"values": {"top": {}, "opt": {}, "hy": {}}, "absent": {"top": [], "opt": [], "hy": []}}
    for sec, names in keys.items():
        src = s if sec == "top" else (s.get(sec) if isinstance(s.get(sec), dict) else {})
        for k in names:
            if k in src:
                snap["values"][sec][k] = src[k]
            else:
                snap["absent"][sec].append(k)
    return snap


def restore(s, snap):
    for sec in ("top", "opt", "hy"):
        dst = section(s, sec)
        for k, v in (snap.get("values", {}).get(sec) or {}).items():
            dst[k] = v
        for k in (snap.get("absent", {}).get(sec) or []):
            dst.pop(k, None)


def apply_values(s, vals):
    for sec in ("top", "opt", "hy"):
        dst = section(s, sec)
        for k, v in vals.get(sec, {}).items():
            dst[k] = v


# ------------------------------------------------------------------------------------------------ the running session
def ensure_session_env():
    """From a TTY the Hyprland / Wayland variables are missing: find the newest running session (best effort)."""
    rt = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    os.environ.setdefault("XDG_RUNTIME_DIR", rt)
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        best, best_t = None, 0
        hdir = os.path.join(rt, "hypr")
        try:
            for name in os.listdir(hdir):
                p = os.path.join(hdir, name)
                for sock in (".socket.sock", ".socket2.sock"):
                    sp = os.path.join(p, sock)
                    if os.path.exists(sp):
                        t = os.path.getmtime(sp)
                        if t >= best_t:
                            best, best_t = name, t
                        break
        except OSError:
            pass
        if best:
            os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = best
    if not os.environ.get("WAYLAND_DISPLAY"):
        try:
            socks = sorted(n for n in os.listdir(rt) if n.startswith("wayland-") and not n.endswith(".lock"))
            if socks:
                os.environ["WAYLAND_DISPLAY"] = socks[0]
        except OSError:
            pass


def run(cmd, timeout=8):
    """(ok, stdout). Never raises: a missing program or a timeout is just 'not ok'."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False, ""


def have(cmd):
    return shutil.which(cmd) is not None


def island_call(fn, timeout=6):
    qs = shutil.which("quickshell") or shutil.which("qs")
    if not qs:
        return False
    ok, _ = run([qs, "ipc", "-p", ISLAND_DIR, "call", "island", fn], timeout)
    return ok


def island_running():
    if not have("pgrep"):
        return False
    ok, out = run(["pgrep", "-f", "quickshell.* -p .*/quickshell/island"], 3)
    return ok and out.strip() != ""


def push_hypr_effects(off):
    """Safe mode on: turn the compositor effects off right now, even if the island never answers."""
    if not have("hyprctl"):
        return
    if off:
        run(["hyprctl", "eval", "hl.config({ decoration = { blur = { enabled = false }, shadow = { enabled = false } }, animations = { enabled = false } })"], 5)


def reload_hard():
    """What the island's own 'reload' does (hyprctl reload, terminal colours, then the island restarts itself)."""
    # first let the running island read the new file, so a save it makes in the next second cannot put its old values back
    island_call("applyFx", 3)
    if island_call("reload"):
        return "reloaded the island"
    # the island does not answer (stuck, or not running): reload Hyprland, then make sure an island comes up with the new file
    if have("hyprctl"):
        run(["hyprctl", "reload"], 8)
    if island_running() and have("pkill"):
        run(["pkill", "-f", "quickshell.* -p .*/quickshell/island"], 3)       # start-shell.sh starts it again by itself
        return "the island did not answer: it was stopped and is starting again"
    starter = os.path.join(RICE, "scripts", "start-shell.sh")
    if os.path.exists(starter):
        try:
            subprocess.Popen(["bash", starter, "island"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            return "the island was not running: starting it"
        except OSError:
            pass
    return "could not reach the island: log out and in again to apply it"


def reload_soft():
    """Read settings.json again inside the running island (no restart). Not running = it reads the file at its next start."""
    if island_call("applyFx"):
        return "applied"
    return "the island is not running (or did not answer): it uses the new values when it starts"


# ------------------------------------------------------------------------------------------------ brightness
def get_brightness():
    if not have("brightnessctl"):
        return None
    ok, out = run(["brightnessctl", "-m"], 4)
    if not ok:
        return None
    try:
        return int(out.strip().splitlines()[0].split(",")[3].rstrip("%"))
    except (IndexError, ValueError):
        return None


def set_brightness(pct):
    if not have("brightnessctl"):
        return False
    ok, _ = run(["brightnessctl", "-q", "--min-value=1", "set", "%d%%" % int(pct)], 4)
    return ok


# ------------------------------------------------------------------------------------------------ safe mode
def safe_active():
    return os.path.exists(SAFE_FILE)


def safe_on(reload=True):
    if safe_active():
        say("Safe mode is already on. `halcyon safe-mode back` restores your values.")
        return 0
    s = load_settings()
    keys = {sec: list(SAFE[sec].keys()) for sec in SAFE}
    snap = snapshot(s, keys)
    snap["saved"] = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        write_json(SAFE_FILE, snap, pretty=True)         # first: if anything below fails, the way back exists
        apply_values(s, SAFE)
        write_json(SETTINGS, s)
    except OSError as e:
        try:
            os.remove(SAFE_FILE)
        except OSError:
            pass
        err("could not write the settings: %s" % e)
        return 1
    say("Safe mode on: blur, shadows, window animations, stars, island motion and other heavy effects are off.")
    if reload:
        ensure_session_env()
        push_hypr_effects(True)
        say(reload_hard().capitalize() + ".")
    say("Back to normal:  halcyon safe-mode back   (or the same shortcut again)")
    return 0


def safe_off(reload=True):
    if not safe_active():
        say("Safe mode is not on, nothing to restore.")
        return 0
    snap = read_json(SAFE_FILE)
    if not isinstance(snap, dict) or "values" not in snap:
        bad = SAFE_FILE + ".bad-" + time.strftime("%Y%m%d-%H%M%S")
        try:
            os.replace(SAFE_FILE, bad)
        except OSError:
            pass
        err("the saved values could not be read (kept as %s). Safe mode is now marked off; set blur, stars and motion again "
            "in Settings, or run `halcyon safe-mode on` then `back`." % bad)
        return 1
    s = load_settings()
    restore(s, snap)
    try:
        write_json(SETTINGS, s)
        os.remove(SAFE_FILE)
    except OSError as e:
        err("could not write the settings: %s" % e)
        return 1
    say("Back to normal: your earlier values are restored.")
    if reload:
        ensure_session_env()
        say(reload_hard().capitalize() + ".")
    return 0


# ------------------------------------------------------------------------------------------------ profiles
def effective_profiles():
    out = {k: dict(v) for k, v in PROFILES.items()}
    ov = read_json(OVERRIDES, {})
    if isinstance(ov, dict):
        for name, vals in ov.items():
            if name in out and isinstance(vals, dict):
                for k, v in vals.items():
                    if k in out[name]:
                        out[name][k] = v
    return out


def valid_profile_values(p):
    """A hand-edited profiles.json must not be able to write nonsense into settings.json."""
    ok = isinstance(p.get("stars"), bool) and isinstance(p.get("blur"), bool)
    m = p.get("motion")
    ok = ok and isinstance(m, (int, float)) and not isinstance(m, bool) and 0 <= m <= 1
    b = p.get("brightness")
    ok = ok and (b is None or (isinstance(b, (int, float)) and not isinstance(b, bool) and 1 <= b <= 100))
    ok = ok and p.get("bar") in (None, "on", "off")
    return ok


def profile_state():
    st = read_json(PROFILE_FILE, {})
    return st if isinstance(st, dict) else {}


def active_profile():
    a = profile_state().get("active")
    return a if a in PROFILES else "custom"


def profile_set(name, reload=True):
    if safe_active():
        err("safe mode is on, so profiles are paused. Run `halcyon safe-mode back` first.")
        return 3
    profs = effective_profiles()
    s = load_settings()
    st = profile_state()
    cur = active_profile()

    if name == "custom":
        snap = st.get("custom")
        if cur == "custom" and not snap:
            say("Already on Custom.")
            return 0
        if not isinstance(snap, dict):
            say("There is no saved setup to bring back; staying as it is.")
            st["active"] = "custom"
            write_json(PROFILE_FILE, st, pretty=True)
            return 0
        # a key that did not exist is deleted, and a live island keeps its old in-memory value for a deleted key; Hyprland was never
        # pushed before when hyprTouched did not exist: in both cases only a full reload really puts things back
        absent = any(snap.get("absent", {}).get(sec) for sec in ("top", "opt", "hy"))
        hard = absent or not snap.get("values", {}).get("top", {}).get("hyprTouched")
        restore(s, snap)
        write_json(SETTINGS, s)
        bright = snap.get("brightness")
        if isinstance(bright, int):
            set_brightness(bright)
        write_json(PROFILE_FILE, {"active": "custom"}, pretty=True)
        say("Custom: your own setup is back.")
        if reload:
            ensure_session_env()
            say((reload_hard() if hard else reload_soft()).capitalize() + ".")
        return 0

    if name not in profs:
        err("unknown profile '%s' (work, gaming, battery, night, custom)" % name)
        return 2
    p = profs[name]
    if not valid_profile_values(p):
        err("profiles.json has a value that is not allowed for '%s' (see `halcyon profile list`); using nothing" % name)
        return 1

    # leaving Custom: keep your own values first (once; switching between profiles keeps the original)
    if cur == "custom" or not isinstance(st.get("custom"), dict):
        custom = snapshot(s, PROFILE_KEYS)
        custom["brightness"] = get_brightness()
        st = {"custom": custom}
    custom = st["custom"]

    top = {"blur": p["blur"], "motion": p["motion"], "profileStars": p["stars"], "hyprTouched": True}
    opt = {"stars": p["stars"], "starsBar": p["stars"]}
    bar = p["bar"]
    now_bar = (s.get("opt") or {}).get("barStyle", "island")
    if bar == "off":
        opt["barStyle"] = "off"
    elif bar == "on" and now_bar == "off":
        was = custom.get("values", {}).get("opt", {}).get("barStyle")
        opt["barStyle"] = was if was in ("island", "notch", "custom") else "island"
    apply_values(s, {"top": top, "opt": opt})
    write_json(SETTINGS, s)
    st["active"] = name
    write_json(PROFILE_FILE, st, pretty=True)

    msg = "%s profile on: stars %s, blur %s, motion %s" % (PROFILE_LABELS[name], "on" if p["stars"] else "off",
                                                          "on" if p["blur"] else "off",
                                                          {0: "off", 0.5: "fast", 1: "normal"}.get(p["motion"], p["motion"]))
    if bar:
        msg += ", top bar " + bar
    if p["brightness"] is not None:
        if set_brightness(p["brightness"]):
            msg += ", brightness %d%%" % p["brightness"]
        else:
            msg += " (brightness not changed: brightnessctl or a backlight was not found)"
    say(msg + ".")
    if reload:
        ensure_session_env()
        say(reload_soft().capitalize() + ".")
    return 0


def profile_list():
    profs = effective_profiles()
    cur = active_profile()
    say("Profiles (now: %s)" % PROFILE_LABELS[cur])
    for n in PROFILES:
        p = profs[n]
        say("  %-8s stars %-3s blur %-3s motion %-6s brightness %-6s top bar %s%s" % (
            n, "on" if p["stars"] else "off", "on" if p["blur"] else "off",
            {0: "off", 0.5: "fast", 1: "normal"}.get(p["motion"], p["motion"]),
            ("%d%%" % p["brightness"]) if p["brightness"] is not None else "leave",
            p["bar"] or "leave", "   <- active" if n == cur else ""))
    say("  custom   your own setup, saved when you leave it")
    say("Change a value: edit %s (see `halcyon profile --help`)." % OVERRIDES)
    return 0


def status(as_json):
    d = {"safe": safe_active(), "profile": active_profile(), "profiles": list(PROFILES.keys())}
    if as_json:
        print(json.dumps(d))
    else:
        say("Safe mode: %s" % ("ON (halcyon safe-mode back)" if d["safe"] else "off"))
        say("Profile: %s" % PROFILE_LABELS[d["profile"]])
    return 0


# ------------------------------------------------------------------------------------------------ main
def passthrough(argv):
    """Everything else (halcyon launcher, halcyon lock ...) is the fish command; from bash it is run through fish."""
    fish = shutil.which("fish")
    if fish:
        os.execv(fish, [fish, "-c", "halcyon $argv", "--"] + argv)
    err("only `safe-mode` and `profile` work without fish; install fish for the other halcyon commands")
    return 2


def main(argv):
    flags = [a for a in argv if a.startswith("--")]
    args = [a for a in argv if not a.startswith("--")]
    reload = "--no-reload" not in flags
    if not args or "--help" in flags or args[0] in ("-h", "help"):
        print(__doc__.strip())
        return 0
    cmd, rest = args[0], args[1:]
    if cmd == "safe-mode":
        sub = rest[0] if rest else "on"
        if sub == "on":
            return safe_on(reload)
        if sub in ("off", "back"):
            return safe_off(reload)
        if sub == "toggle":
            return safe_off(reload) if safe_active() else safe_on(reload)
        if sub == "status":
            return status("--json" in flags)
        err("usage: halcyon safe-mode [on|back|toggle|status]")
        return 2
    if cmd == "profile":
        sub = rest[0] if rest else "list"
        if sub == "list":
            return profile_list()
        if sub == "status":
            return status("--json" in flags)
        return profile_set(sub.lower(), reload)
    if cmd == "status":
        return status("--json" in flags)
    return passthrough(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
