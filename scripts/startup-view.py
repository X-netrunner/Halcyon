#!/usr/bin/env python3
"""startup-view.py : what starts with the desktop, what is running because of it, and what it costs.
The island's "Startup & processes" window (quickshell/island/StartupWindow.qml) polls this ONLY while it is open;
nothing stays running in the background.

  startup-view.py list                     one line of JSON: startup items (+ their processes) and every process of yours
  startup-view.py toggle MODE KEY 1|0      MODE = conf (Halcyon's own, via startup-conf.sh) | unit (systemd --user) | xdg (autostart .desktop)
  startup-view.py end PID                  asks one of your own processes to quit (SIGTERM); the desktop itself is protected
  startup-view.py keep ID                  "Keep it": that startup item is not suggested for turning off any more

"suggest" in the list is the window's Suggestions tab: startup items that are running and can be turned off because they do
nothing useful on THIS machine (no touchpad, no Bluetooth adapter ...), because Halcyon already covers what they do, or because
they are chat / sync apps that can simply be opened when you need them. Nothing is ever turned off without you pressing the button.

Memory is PSS (shared pages split fairly between the processes that map them, the same number halcyon-mem-where.sh uses),
so the total is not inflated by shared libraries. CPU is sampled over ~0.4 s and is "percent of ONE core" (100 = one core
busy, a process with several threads can pass 100); the window also shows it as a share of the whole processor (ncpu).
"""
import json, os, re, shlex, signal, subprocess, sys, time

HOME = os.path.expanduser("~")
UID = os.getuid()
RICE = os.environ.get("HALCYON_DIR", HOME + "/.config/Halcyon")
TICK = os.sysconf("SC_CLK_TCK")
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024
STATE = HOME + "/.local/state/island"
KEEP = STATE + "/startup-keep"
PROTECTED = re.compile(r"(^|/)(Hyprland|quickshell|systemd|dbus-broker|dbus-daemon|dbus-broker-launch|start-shell\.sh|login|sddm|greetd)( |$)")


def sh(args, t=5):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=t).stdout
    except Exception:
        return ""


# ------------------------------------------------------------------ processes
def read_stat(pid):
    with open("/proc/%s/stat" % pid) as f:
        s = f.read()
    r = s.rfind(")")
    rest = s[r + 2:].split()
    return s[s.find("(") + 1:r], int(rest[1]), int(rest[11]) + int(rest[12]), int(rest[21]) * PAGE_KB


def pss_kb(pid, rss_kb):
    try:
        with open("/proc/%s/smaps_rollup" % pid) as f:
            for ln in f:
                if ln.startswith("Pss:"):
                    return int(ln.split()[1])
    except Exception:
        pass
    return rss_kb


def scan():
    procs = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            if os.stat("/proc/" + d).st_uid != UID:
                continue
            comm, ppid, ticks, rss = read_stat(d)
            with open("/proc/%s/cmdline" % d, "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
            if cmd == "":
                continue                       # kernel thread / zombie
            procs[int(d)] = {"pid": int(d), "ppid": ppid, "name": comm, "cmd": cmd, "ticks": ticks, "rss": rss, "pss": 0, "cpu": 0.0}
        except Exception:
            continue
    t0 = time.time()
    time.sleep(0.4)
    dt = max(0.05, time.time() - t0)
    for pid, p in list(procs.items()):
        try:
            _, _, t1, rss = read_stat(pid)
            p["cpu"] = round(max(0, t1 - p["ticks"]) / TICK / dt * 100, 1)
            p["pss"] = pss_kb(pid, rss)
        except Exception:
            p["pss"] = p["rss"]
    return procs


def tree(seed, kids):
    out, st = set(), list(seed)
    while st:
        p = st.pop()
        if p in out:
            continue
        out.add(p)
        st.extend(kids.get(p, []))
    return out


# ------------------------------------------------------------------ the startup sources
# Halcyon's own parts. key = a startup-conf.sh key (switchable); `on`/`off` are the values it stores.
CATALOG = [
    dict(id="hyprland", name="Hyprland", desc="The compositor: windows, workspaces, input", match=r"(^|/)Hyprland( |$)", core=True, kids=False),
    dict(id="island", name="Island shell (Quickshell)", desc="Bar, wallpaper layer, notifications, lock screen and every overlay, in one process", match=r"(^|/)quickshell( |$)|start-shell\.sh", core=True),
    dict(id="polkit", name="Polkit agent", desc="The password prompt for system actions", match=r"hyprpolkitagent|polkit-(gnome|kde)-authentication-agent", key="POLKIT", on="auto", off="none", login=True),
    dict(id="portal", name="Screen-sharing portal", desc="xdg-desktop-portal-hyprland: off = it starts only when an app asks", match=r"xdg-desktop-portal-hyprland", key="PORTAL", on="login", off="demand", login=True),
    dict(id="clipboard", name="Clipboard history", desc="Two wl-paste watchers + cliphist", match=r"wl-pas[t].*--watch cliphist", key="CLIPBOARD", on="1", off="0"),
    dict(id="gestures", name="Touchpad edge gestures", desc="touchpad-gestures service: edge volume / brightness / track", match=r"touchpad-gestures", key="GESTURES", on="1", off="0"),
    dict(id="nm", name="nm-applet", desc="Tray applet for VPN / 802.1x prompts (the island has its own Wi-Fi list)", match=r"(^|/)nm-applet( |$)", key="NM_APPLET", on="1", off="0", needs="nm"),
    dict(id="blueman", name="blueman-applet", desc="Tray applet for pairing Bluetooth devices", match=r"blueman-applet", key="BLUEMAN", on="1", off="0", needs="blueman"),
    dict(id="hypridle", name="Idle lock + sleep", desc="hypridle, set in Settings > Sleep & lock", match=r"(^|/)hypridle( |$)"),
    dict(id="power", name="Auto power manager", desc="power-manager daemon: battery / load / heat aware profiles (Auto mode)", match=r"bin/power-manager( |$)"),
]
UNIT_SKIP = re.compile(r"^(touchpad-gestures|power-manager)\.service$")


def conf_state():
    out = sh(["bash", RICE + "/scripts/startup-conf.sh", "list"])
    try:
        return json.loads(out)
    except Exception:
        return {}


def hypr_user_lines():
    """Your own `hl.exec_cmd("...")` lines in hypr-user.lua (commented-out ones are ignored)."""
    out = []
    try:
        with open(RICE + "/hypr-user.lua", errors="replace") as f:
            for ln in f:
                if ln.lstrip().startswith("--"):
                    continue
                m = re.search(r'exec_cmd\(\s*"((?:[^"\\]|\\.)*)"', ln)
                if m and "hl.bind" not in ln:
                    out.append(m.group(1).replace('\\"', '"'))
    except Exception:
        pass
    return out


def prog_of(cmd):
    try:
        for tok in shlex.split(cmd.replace("&&", ";").split(";")[0].rstrip(" &")):
            if "=" in tok.split("/")[0] and not tok.startswith("/"):
                continue                      # VAR=value prefix
            if tok in ("sh", "bash", "env", "exec", "setsid", "nohup"):
                continue
            return os.path.basename(tok)
    except Exception:
        pass
    return ""


def parse_desktop(path):
    d, inside = {}, False
    try:
        for ln in open(path, errors="replace"):
            ln = ln.strip()
            if ln.startswith("["):
                inside = ln == "[Desktop Entry]"
            elif inside and "=" in ln and not ln.startswith("#"):
                k, v = ln.split("=", 1)
                d.setdefault(k.strip(), v.strip())
    except Exception:
        pass
    return d


def xdg_entries():
    seen, out = {}, []
    for base in (HOME + "/.config/autostart", "/etc/xdg/autostart"):
        try:
            files = sorted(os.listdir(base))
        except Exception:
            continue
        for fn in files:
            if fn.endswith(".desktop") and fn not in seen:
                seen[fn] = base + "/" + fn
    for fn, path in seen.items():
        d = parse_desktop(path)
        only, notin = d.get("OnlyShowIn", ""), d.get("NotShowIn", "")
        if (only and "Hyprland" not in only.split(";")) or "Hyprland" in notin.split(";"):
            continue
        exe = prog_of(re.sub(r"%[a-zA-Z]", "", d.get("Exec", "")))
        if exe in ("nm-applet", "blueman-applet", ""):
            continue
        off = d.get("Hidden", "").lower() == "true" or d.get("X-GNOME-Autostart-enabled", "").lower() == "false"
        out.append(dict(file=fn, name=d.get("Name", fn[:-8]), desc=d.get("Comment") or d.get("Exec", ""), exe=exe, off=off))
    return out


def systemd_units():
    files = sh(["systemctl", "--user", "list-unit-files", "--type=service", "--no-legend", "--plain"])
    state = {}
    for ln in files.splitlines():
        p = ln.split()
        if len(p) >= 2 and p[1] in ("enabled", "enabled-runtime", "linked", "disabled"):
            state[p[0]] = p[1]
    run = sh(["systemctl", "--user", "list-units", "--type=service", "--state=running", "--no-legend", "--plain"])
    names = [n for n, s in state.items() if s != "disabled"]
    for ln in run.splitlines():
        p = ln.split()
        if p and p[0] not in names:
            names.append(p[0])
    # the Halcyon units that are disabled on purpose (started by the island) are still worth showing when they run
    out = []
    for i in range(0, len(names), 50):
        blob = sh(["systemctl", "--user", "show", "-p", "Id,Description,MainPID,ActiveState,UnitFileState,Transient"] + names[i:i + 50], 8)
        for block in blob.strip().split("\n\n"):
            kv = dict(l.split("=", 1) for l in block.splitlines() if "=" in l)
            if kv.get("Id") and not UNIT_SKIP.match(kv["Id"]):
                out.append(kv)
    return out


# ------------------------------------------------------------------ suggestions
def has_touchpad():
    try:
        with open("/proc/bus/input/devices", errors="replace") as f:
            return any(l.startswith("N:") and re.search(r"touchpad|trackpad", l, re.I) for l in f)
    except Exception:
        return True            # cannot tell: do not claim it is missing


def has_bluetooth():
    try:
        return len(os.listdir("/sys/class/bluetooth")) > 0
    except Exception:
        return False


def load_keep():
    try:
        with open(KEEP) as f:
            return {l.strip() for l in f if l.strip()}
    except Exception:
        return set()


# chat / sync / launcher style apps: nothing breaks when they start later, by hand
CHATTY = re.compile(r"steam|discord|vesktop|spotify|telegram|slack|teams|zoom|skype|signal|element|whatsapp|dropbox|onedrive|"
                    r"nextcloud|megasync|insync|syncthing|obsidian|thunderbird|evolution|kdeconnect|razer|piper|ratbag|solaar|"
                    r"flameshot|ollama|docker|onedriver|rclone", re.I)
# user services that are safe to switch off (audio, portals, keyring, polkit ... are never in this list)
UNIT_TIPS = [
    (r"^(tracker-|localsearch)", "safe", "Indexes your files for desktop search and reads the disk in the background. Halcyon's launcher does not use it."),
    (r"^evolution-", "safe", "Contacts / calendar helpers for the Evolution mail app. Only needed if you use Evolution."),
    (r"^kdeconnect", "maybe", "The phone link (KDE Connect). Turn it off if you do not use it."),
    (r"^syncthing", "maybe", "File sync in the background. Start it by hand when you want to sync."),
]


def suggestions(items):
    keep = load_keep()
    out = []

    def add(it, level, why):
        tg = it.get("toggle")
        if it["id"] in keep or not tg or not tg.get("on") or it.get("core") or it.get("missing") or it["count"] == 0:
            return
        out.append(dict(id=it["id"], name=it["name"], level=level, why=why, mb=it["mem"]))

    touchpad, bluetooth = has_touchpad(), has_bluetooth()
    for it in items:
        i = it["id"]
        if i == "cat:gestures" and not touchpad:
            add(it, "safe", "No touchpad was found on this machine, so it has nothing to react to.")
        elif i == "cat:blueman" and not bluetooth:
            add(it, "safe", "No Bluetooth adapter was found.")
        elif i == "cat:nm":
            add(it, "maybe", "The island has its own Wi-Fi list. The applet is only needed for VPN and 802.1x (work / campus Wi-Fi) password prompts.")
        elif i == "cat:portal":
            add(it, "maybe", "Nothing needs it until an app wants to share the screen, and with it off it starts by itself at that moment. Applies at the next login.")
        elif i.startswith("unit:"):
            for rx, lvl, why in UNIT_TIPS:
                if re.search(rx, it["name"]):
                    add(it, lvl, why)
                    break
        elif i.startswith("xdg:"):
            if CHATTY.search(it["name"] + " " + it.get("desc", "")):
                add(it, "maybe", "A chat / sync / launcher app that starts with the desktop and keeps %d MB in memory. You can open it yourself when you need it." % round(it["mem"]))
            elif it["mem"] >= 150:
                add(it, "maybe", "Starts with the desktop and keeps %d MB in memory all the time. If you do not need it right away, open it by hand instead." % round(it["mem"]))
    out.sort(key=lambda t: (t["level"] != "safe", -t["mb"]))
    return out


# ------------------------------------------------------------------ list
def cmd_list():
    procs = scan()
    kids = {}
    for p in procs.values():
        kids.setdefault(p["ppid"], []).append(p["pid"])
    conf = conf_state()
    has = conf.get("has", {}) if isinstance(conf, dict) else {}
    claimed, items = set(), []

    def make(id_, kind, name, desc, seeds, follow=True, **extra):
        pids = tree(seeds, kids) if follow else set(seeds)
        pids = {p for p in pids if p in procs} - claimed
        claimed.update(pids)
        it = dict(id=id_, kind=kind, name=name, desc=desc, pids=sorted(pids), count=len(pids),
                  mem=round(sum(procs[p]["pss"] for p in pids) / 1024, 1),
                  cpu=round(sum(procs[p]["cpu"] for p in pids), 1), toggle=None, core=False, missing=False, off=False)
        it.update(extra)
        items.append(it)
        return it

    def find(rx):
        r = re.compile(rx)
        return [p["pid"] for p in procs.values() if r.search(p["cmd"]) and p["pid"] != os.getpid()]

    for c in CATALOG:
        seeds = find(c["match"])
        key = c.get("key")
        tog = None
        off = False
        if key:
            cur = str(conf.get(key, "")).lower()
            if isinstance(conf.get(key), bool):
                cur = "1" if conf[key] else "0"
            on = cur == c["on"]
            tog = dict(mode="conf", key=key, on=on, login=bool(c.get("login")))
            off = not on
        missing = bool(c.get("needs")) and has.get(c["needs"]) is False
        make("cat:" + c["id"], "halcyon", c["name"], c["desc"], seeds, c.get("kids", True),
             toggle=tog, core=bool(c.get("core")), missing=missing, off=off and not seeds)

    for i, line in enumerate(hypr_user_lines()):
        exe = prog_of(line)
        seeds = find(r"(^|/)%s( |$)" % re.escape(exe)) if exe else []
        make("user:%d" % i, "hypr", exe or line[:30], "hypr-user.lua: " + line, seeds)

    for kv in systemd_units():
        uid = kv["Id"]
        try:
            mp = int(kv.get("MainPID", "0"))
        except ValueError:
            mp = 0
        fstate = kv.get("UnitFileState", "")
        can = fstate in ("enabled", "enabled-runtime", "disabled") and kv.get("Transient", "no") != "yes"
        make("unit:" + uid, "service", uid[:-8], kv.get("Description", ""), [mp] if mp else [],
             toggle=dict(mode="unit", key=uid, on=fstate.startswith("enabled"), login=False) if can else None,
             off=(fstate == "disabled" and mp == 0))

    for e in xdg_entries():
        seeds = find(r"(^|/)%s( |$)" % re.escape(e["exe"]))
        make("xdg:" + e["file"], "autostart", e["name"], e["desc"], seeds,
             toggle=dict(mode="xdg", key=e["file"], on=not e["off"], login=False), off=e["off"] and not seeds)

    owner = {}
    for it in items:
        for p in it["pids"]:
            owner[p] = it["name"]
    plist = []
    for p in sorted(procs.values(), key=lambda x: -x["pss"])[:80]:
        plist.append(dict(pid=p["pid"], name=p["name"], cmd=p["cmd"][:160], mem=round(p["pss"] / 1024, 1), cpu=p["cpu"],
                          owner=owner.get(p["pid"], ""), protected=bool(PROTECTED.search(p["cmd"])) or p["pid"] == os.getpid()))
    meminfo = {}
    try:
        for ln in open("/proc/meminfo"):
            k, v = ln.split(":")
            meminfo[k] = int(v.split()[0])
    except Exception:
        pass
    items.sort(key=lambda it: (-it["mem"], it["name"].lower()))
    print(json.dumps(dict(
        items=items, procs=plist, n_procs=len(procs), suggest=suggestions(items), ncpu=os.cpu_count() or 1,
        session_mb=round(sum(p["pss"] for p in procs.values()) / 1024, 1),
        startup_mb=round(sum(it["mem"] for it in items), 1),
        total_mb=round(meminfo.get("MemTotal", 0) / 1024), avail_mb=round(meminfo.get("MemAvailable", 0) / 1024))))


# ------------------------------------------------------------------ actions
CONF_VALUES = {c["key"]: (c["on"], c["off"]) for c in CATALOG if c.get("key")}


def set_xdg(fn, on):
    if "/" in fn or not fn.endswith(".desktop"):
        return 2
    user = HOME + "/.config/autostart/" + fn
    src = user if os.path.exists(user) else "/etc/xdg/autostart/" + fn
    try:
        lines = open(src, errors="replace").read().splitlines()
    except Exception:
        return 1
    lines = [l for l in lines if not re.match(r"\s*(Hidden|X-GNOME-Autostart-enabled)\s*=", l)]
    if not on:
        idx = next((i for i, l in enumerate(lines) if l.strip() == "[Desktop Entry]"), -1)
        lines.insert(idx + 1, "Hidden=true")
    os.makedirs(os.path.dirname(user), exist_ok=True)
    with open(user, "w") as f:
        f.write("\n".join(lines) + "\n")
    return 0


def main():
    a = sys.argv[1:] or ["list"]
    if a[0] == "list":
        cmd_list()
    elif a[0] == "toggle" and len(a) >= 4:
        mode, key, on = a[1], a[2], a[3] in ("1", "true", "on")
        if mode == "conf" and key in CONF_VALUES:
            return subprocess.call(["bash", RICE + "/scripts/startup-conf.sh", "set", key, CONF_VALUES[key][0 if on else 1]])
        if mode == "unit" and re.fullmatch(r"[A-Za-z0-9@:_.\\-]+\.service", key):
            return subprocess.call(["systemctl", "--user", "enable" if on else "disable", "--now", key])
        if mode == "xdg":
            return set_xdg(key, on)
        return 2
    elif a[0] == "keep" and len(a) >= 2 and re.fullmatch(r"[\w:.@+-]+", a[1]):
        try:
            os.makedirs(STATE, exist_ok=True)
            if a[1] not in load_keep():
                with open(KEEP, "a") as f:
                    f.write(a[1] + "\n")
        except Exception:
            return 1
    elif a[0] == "end" and len(a) >= 2 and a[1].isdigit():
        pid = int(a[1])
        if pid < 2:
            return 3
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
            if os.stat("/proc/%d" % pid).st_uid != UID or PROTECTED.search(cmd) or pid == os.getpid():
                return 3
            os.kill(pid, signal.SIGTERM)
        except Exception:
            return 1
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
