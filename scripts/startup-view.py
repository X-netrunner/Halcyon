#!/usr/bin/env python3
"""startup-view.py : what starts with the desktop, what is running because of it, and what it costs.
The island's "Startup & processes" window (quickshell/island/StartupWindow.qml) polls this ONLY while it is open;
nothing stays running in the background.

  startup-view.py list [--ram MB] [--cpu PCT] [--auto]
                                           one line of JSON: startup items (+ their processes) and every process of yours, plus
                                           "health": how much Halcyon as a whole uses against the two limits (MB of RAM, % of the
                                           whole processor; Settings > Performance & memory) and, when it is over, the likely causes
  startup-view.py toggle MODE KEY 1|0      MODE = conf (Halcyon's own, via startup-conf.sh) | unit (systemd --user) | xdg (autostart .desktop)
  startup-view.py end PID                  asks one of your own processes to quit (SIGTERM); the desktop itself is protected
  startup-view.py adapt-sample|adapt-status|adapt-reset
                                           Adaptive limits (Settings > Performance & memory > Limits): sample = one reading of Halcyon's RAM / CPU
                                           (the island runs it every 5 min while Adaptive is on), status = what has been learned (JSON), reset = start over.
                                           "list --auto" then reports the learned limits under "adaptive".
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
    dict(id="clipboard", name="Clipboard history", desc="Two wl-paste watchers + cliphist (clip-store.sh keeps password-manager copies out)", match=r"wl-pas[t].*--watch.*(clip-store|cliphist)", key="CLIPBOARD", on="1", off="0"),
    dict(id="audiofocus", name="One thing plays at a time", desc="audio-focus.sh: pauses the other player and brings it back after", match=r"audio-focus\.sh", key="AUDIO_FOCUS", on="1", off="0"),
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



# ------------------------------------------------------------------ health: Halcyon as a whole against its limits
DEF_RAM_MB, DEF_CPU_PCT = 600, 10.0


def island_opts():
    """The island's saved options (settings.json), so the advice can say what is actually switched on."""
    try:
        with open(STATE + "/settings.json") as f:
            d = json.load(f)
        o = dict(d.get("opt") or {})
        for k in ("blur", "shadows", "hyprAnim"):
            if k in d:
                o[k] = d[k]
        return o
    except Exception:
        return {}


def age_hours(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            s = f.read()
        st = int(s[s.rfind(")") + 2:].split()[19])
        with open("/proc/uptime") as f:
            up = float(f.read().split()[0])
        return max(0.0, (up - st / TICK) / 3600)
    except Exception:
        return 0.0


def label_of(p):
    """A readable name for one process: the two quickshell instances are told apart by the folder they run."""
    c = p["cmd"]
    if re.search(r"(^|/)(quickshell|qs)( |$)", c):
        if "/wallpaper" in c:
            return "wallpaper layer"
        if "/island" in c:
            return "island shell"
    return p["name"]


def pt(label, text):
    return dict(t="text", label=label, text=text)


def preset(v, label=None):
    return dict(t="preset", v=v, label=label or ("Switch to %s resource use" % v.capitalize()))


def mem_advice(it, inside, o, procs):
    """(causes, actions) for one Halcyon part whose RAM is high."""
    i = it["id"]
    causes, actions = [], []
    res = o.get("resMode", "high")
    if i == "cat:island":
        wall = sum(p["pss"] for p in inside if label_of(p) == "wallpaper layer") / 1024
        if wall > it["mem"] * 0.3:
            causes.append("The wallpaper layer alone holds %d MB: a high-resolution wallpaper is decoded and kept in memory, and a live wallpaper keeps frames as well." % round(wall))
            actions.append(pt("Use a smaller wallpaper", "Pick a picture close to your screen's resolution (Wallpaper gallery), and keep the live wallpaper off (scripts/toggle_livewallpaper.sh) unless you want it."))
        if res == "high":
            causes.append("Resource use is on High: blur, shadows, the full tree view and the moving stars all keep their own images and buffers.")
        if o.get("stars") is not False or o.get("starsBar") is not False:
            causes.append("Stars and constellations are on; every layer of them has its own textures.")
        old = max([age_hours(p["pid"]) for p in inside if label_of(p) == "island shell"] or [0])
        if old >= 24:
            causes.append("The island has been running for %d hours. A QML program's memory creeps up slowly and is only handed back when it restarts." % round(old))
            actions.append(pt("Restart the island", "Log out and back in. (A plain `pkill quickshell` ends it for good: start-shell.sh treats that as closing on purpose.)"))
        causes.append("Windows that are open now (Overview, Settings, the gallery) keep their images until they close.")
        if res != "low":
            actions.append(preset("low" if res == "medium" else "medium"))
        actions.append(pt("See where it is", "Run  ~/.config/Halcyon/scripts/halcyon-mem-where.sh  in a terminal: it splits the island's memory into program data, window buffers and graphics drivers."))
    elif i == "cat:hyprland":
        causes.append("Hyprland keeps a buffer for every window and every blurred layer; many windows, high blur passes and shadows add up.")
        if o.get("blur") is not False:
            causes.append("Blur is on.")
        if o.get("shadows") is not False:
            causes.append("Shadows are on.")
        if res != "low":
            actions.append(preset("low" if res == "medium" else "medium"))
        actions.append(pt("Close what you do not use", "Windows on other workspaces still cost memory. Close old ones (the Overview tree shows how much each workspace uses)."))
    elif i == "cat:clipboard":
        causes.append("The clipboard history keeps pictures you copied; a long history makes cliphist and its watchers large.")
        actions.append(pt("Empty it", "Run  cliphist wipe  in a terminal. Or turn the history off below."))
        actions.append(dict(t="toggle", id=i, label="Turn off clipboard history"))
    elif i in ("cat:nm", "cat:blueman"):
        causes.append("A tray applet starts a whole GTK toolkit for one small icon; 30-50 MB is normal for it.")
        actions.append(dict(t="toggle", id=i, label="Turn off " + it["name"]))
    elif i == "cat:power":
        causes.append("The power manager is a small program; more than a few MB means it is holding results it should drop, or it is stuck.")
        actions.append(pt("Use another one", "Settings > Power & sleep > Power manager: pick power-profiles-daemon or another manager, then it is stopped."))
    else:
        causes.append("%s is larger than a helper like it normally is." % it["name"])
    return causes, actions


def cpu_advice(it, inside, o, procs):
    """(causes, actions) for one Halcyon part whose CPU is high."""
    i = it["id"]
    causes, actions = [], []
    res = o.get("resMode", "high")
    kid = {}
    for p in inside:
        kid[p["name"]] = kid.get(p["name"], 0) + p["cpu"]
    if i == "cat:island":
        if o.get("fps", 0) in (0, None):
            causes.append("The tree view and the constellations redraw at your screen's full frame rate (Max).")
            actions.append(pt("Cap the frame rate", "Settings > Performance & memory > Tree view & constellation frame rate: 30 or 60."))
        if o.get("starsBar") is not False:
            causes.append("The moving stars in the bar are on; they animate all the time.")
            actions.append(pt("Stop the moving stars", "Settings > Constellations > Moving stars: off."))
        if kid.get("cava", 0) > 3:
            causes.append("The music bars (cava) are running and drawing while music plays.")
            actions.append(pt("Lighten the music bars", "Settings > Bar > Music bars quality: Light (about half the work) or switch the bars off."))
        if kid.get("hx", 0) > 3:
            causes.append("The Rust helper hx (workspace and stats readers) is busy.")
            actions.append(pt("Slow the readers", "Settings > Performance > Update speed: Medium, Low or Adaptive."))
        if o.get("lines") == "cpu":
            causes.append("Line drawing is set to CPU; the GPU setting draws the same lines for free.")
            actions.append(pt("Draw lines on the GPU", "Settings > Performance & memory > Line drawing: GPU."))
        if o.get("bgRefresh", "normal") == "normal":
            causes.append("Update speed is High: the CPU, battery, Wi-Fi and Bluetooth readers look again every 2-4 s.")
        if res == "high":
            causes.append("Resource use is on High: every effect is on, as designed.")
        if not causes:
            causes.append("No single option explains it; an overlay that is open (Overview, a gallery, a video wallpaper) is the usual reason.")
        if res != "low":
            actions.append(preset("low" if res == "medium" else "medium"))
    elif i == "cat:hyprland":
        causes.append("The compositor works hardest while windows animate, blur is on, or a game / video is composited.")
        if o.get("blur") is not False:
            causes.append("Blur is on, and it is redrawn behind every translucent window and bar.")
        if o.get("hyprAnim") is not False:
            causes.append("Window animations are on.")
        if res != "low":
            actions.append(preset("low" if res == "medium" else "medium"))
        actions.append(pt("Gaming mode", "SUPER+F10 switches the effects off and gives the game the CPU and GPU."))
    elif i == "cat:power":
        causes.append("The power manager wakes up on a timer and starts short helper programs (nvidia-smi, powerprofilesctl) every time; the helpers' CPU is counted with it.")
        causes.append("A tight loop or a very short poll interval makes it busy even when nothing changes.")
        actions.append(pt("Use another one", "Settings > Power & sleep > Power manager: choose another manager while you look into it."))
        actions.append(pt("Check its interval", "Look at the poll interval in src/power-manager (the main loop sleep) and make it longer; 2-5 s is plenty."))
    elif i == "cat:gestures":
        causes.append("The touchpad edge-gesture service reads the touchpad all the time; a loop without waiting for events keeps a core busy.")
        actions.append(dict(t="toggle", id=i, label="Turn off touchpad edge gestures"))
    elif i == "cat:clipboard":
        causes.append("The clipboard watchers wake up on every copy; an app that copies constantly (a terminal, a game) keeps them busy.")
        actions.append(dict(t="toggle", id=i, label="Turn off clipboard history"))
    else:
        causes.append("%s is using more CPU than a helper like it should; it may be stuck." % it["name"])
    return causes, actions


def health_report(items, procs, ncpu, meminfo, ram_lim, cpu_lim):
    o = island_opts()
    halc = [it for it in items if it["kind"] == "halcyon" and it["count"] > 0]
    ram = round(sum(it["mem"] for it in halc), 1)
    cpu_core = round(sum(it["cpu"] for it in halc), 1)
    pct = cpu_core / max(1, ncpu)
    over_ram, over_cpu = ram > ram_lim, pct > cpu_lim
    findings = []

    def inside_of(it):
        ins = [procs[p] for p in it["pids"] if p in procs]
        ins.sort(key=lambda p: -p["pss"])
        return ins

    def breakdown(it, by):
        ins = inside_of(it)
        if len(ins) < 2:
            return ""
        if by == "mem":
            return "Inside: " + ", ".join("%s %d MB" % (label_of(p), round(p["pss"] / 1024)) for p in ins[:4] if p["pss"] > 2048)
        ins.sort(key=lambda p: -p["cpu"])
        return "Inside: " + ", ".join("%s %.1f%%" % (label_of(p), p["cpu"] / ncpu) for p in ins[:4] if p["cpu"] > 1)

    if ram > ram_lim * 0.45:           # QML shows these only while Halcyon is over the RAM limit
        for it in sorted(halc, key=lambda x: -x["mem"])[:4]:
            if it["mem"] < max(20, ram_lim * 0.08):
                continue
            causes, actions = mem_advice(it, inside_of(it), o, procs)
            findings.append(dict(kind="ram", id=it["id"], name=it["name"], value="%s MB" % round(it["mem"]),
                                 share=round(100 * it["mem"] / max(1, ram)), detail=breakdown(it, "mem"), causes=causes, actions=actions))
    if pct > cpu_lim * 0.6:            # ... and these only after it has been over the CPU limit for two readings in a row
        for it in sorted(halc, key=lambda x: -x["cpu"])[:3]:
            if it["cpu"] / ncpu < max(0.8, cpu_lim * 0.12):
                continue
            causes, actions = cpu_advice(it, inside_of(it), o, procs)
            findings.append(dict(kind="cpu", id=it["id"], name=it["name"], value="%.1f%%" % (it["cpu"] / ncpu),
                                 share=round(100 * it["cpu"] / max(0.1, cpu_core)), detail=breakdown(it, "cpu"), causes=causes, actions=actions))

    # the machine as a whole: not Halcyon's fault, but it is what makes everything feel slow
    total, avail = meminfo.get("MemTotal", 0) / 1024, meminfo.get("MemAvailable", 0) / 1024
    swap_used = (meminfo.get("SwapTotal", 0) - meminfo.get("SwapFree", 0)) / 1024
    if total and avail < total * 0.12:
        mine = {p for it in halc for p in it["pids"]}
        others = sorted((p for pid, p in procs.items() if pid not in mine), key=lambda p: -p["pss"])[:3]
        names = ", ".join("%s %d MB" % (p["name"], round(p["pss"] / 1024)) for p in others)
        acts = [dict(t="end", pid=p["pid"], name=p["name"], label="End %s (%d MB)" % (p["name"], round(p["pss"] / 1024))) for p in others
                if not PROTECTED.search(p["cmd"]) and p["pss"] > 150 * 1024]
        causes = ["Only %d MB of %d MB is free. Halcyon uses %d MB of what is taken; the rest is other programs: %s." % (round(avail), round(total), round(ram), names)]
        if swap_used > 512:
            causes.append("%d MB is already pushed out to swap, so everything that was moved there is slow to come back." % round(swap_used))
        findings.append(dict(kind="machine", id="machine", name="The whole machine is short of memory", value="%d MB free" % round(avail),
                             share=0, detail="", causes=causes, actions=acts))

    status = "over" if (over_ram or over_cpu) else ("near" if (ram > ram_lim * 0.85 or pct > cpu_lim * 0.85) else "ok")
    return dict(status=status, ram_mb=ram, ram_limit=ram_lim, cpu_pct=round(pct, 1), cpu_limit=cpu_lim, findings=findings)


# ------------------------------------------------------------------ adaptive limits
# Settings > Performance & memory > Limits: Adaptive. Every 5 min (only while Adaptive is on) the island runs `adapt-sample`, which appends one
# reading of Halcyon's own RAM and CPU to STATE/adaptive.tsv. After ADAPT_DAYS days and ADAPT_MIN readings the limits are worked out from the
# last ADAPT_KEEP_DAYS days: the busy 5 % of the time (95th percentile) plus headroom, kept inside the same range the manual sliders have.
# Nothing is changed or stopped by these limits: like the manual ones they only decide when the Health tab speaks up.
ADAPT_LOG = STATE + "/adaptive.tsv"
ADAPT_DAYS, ADAPT_MIN, ADAPT_KEEP_DAYS = 3, 150, 14
ADAPT_RAM_RANGE, ADAPT_CPU_RANGE = (300, 1500), (3, 30)       # the manual sliders' ranges
ADAPT_RAM_HEADROOM, ADAPT_CPU_HEADROOM = 1.25, 1.5


def adapt_read():
    now, out = time.time(), []
    try:
        with open(ADAPT_LOG) as f:
            for ln in f:
                try:
                    t, r, c = ln.split("\t")
                    t, r, c = float(t), float(r), float(c)
                except ValueError:
                    continue
                if now - t <= ADAPT_KEEP_DAYS * 86400:
                    out.append((t, r, c))
    except OSError:
        pass
    return out


def pct95(vals):
    v = sorted(vals)
    return v[min(len(v) - 1, int(len(v) * 0.95))] if v else 0.0


def adapt_status():
    rows = adapt_read()
    st = dict(state="learning", need_days=ADAPT_DAYS, days=0.0, samples=len(rows), ram_limit=None, cpu_limit=None, base_ram=None, base_cpu=None)
    if not rows:
        return st
    st["days"] = round((rows[-1][0] - rows[0][0]) / 86400, 2)
    if st["days"] >= ADAPT_DAYS and len(rows) >= ADAPT_MIN:
        br, bc = pct95([r[1] for r in rows]), pct95([r[2] for r in rows])
        ram = int(-(-br * ADAPT_RAM_HEADROOM // 50) * 50)                                    # up to the next 50 MB
        cpu = int(-(-(bc * ADAPT_CPU_HEADROOM + 1) // 1))                                    # up to the next whole percent
        st.update(state="ready", base_ram=round(br), base_cpu=round(bc, 1),
                  ram_limit=max(ADAPT_RAM_RANGE[0], min(ADAPT_RAM_RANGE[1], ram)),
                  cpu_limit=max(ADAPT_CPU_RANGE[0], min(ADAPT_CPU_RANGE[1], cpu)))
    return st


def cmd_adapt_sample():
    d = collect(DEF_RAM_MB, DEF_CPU_PCT)
    h = d["health"]
    os.makedirs(STATE, exist_ok=True)
    rows = adapt_read()
    if len(rows) > 4500:                                          # 14 days at one reading per 5 min is about 4000: keep the file from growing
        with open(ADAPT_LOG + ".tmp", "w") as f:
            f.writelines("%.0f\t%s\t%s\n" % r for r in rows[-4000:])
        os.replace(ADAPT_LOG + ".tmp", ADAPT_LOG)
    with open(ADAPT_LOG, "a") as f:
        f.write("%.0f\t%s\t%s\n" % (time.time(), h["ram_mb"], h["cpu_pct"]))


def cmd_adapt_reset():
    try:
        os.remove(ADAPT_LOG)
    except OSError:
        pass


# ------------------------------------------------------------------ list
def cmd_list(ram_lim=DEF_RAM_MB, cpu_lim=DEF_CPU_PCT, auto=False):
    ad = adapt_status() if auto else None
    if ad and ad["state"] == "ready":
        ram_lim, cpu_lim = ad["ram_limit"], ad["cpu_limit"]
    d = collect(ram_lim, cpu_lim)
    if ad:
        d["adaptive"] = ad
    print(json.dumps(d))


def collect(ram_lim, cpu_lim):
    procs = scan()
    kids = {}
    for p in procs.values():
        kids.setdefault(p["ppid"], []).append(p["pid"])
    me = tree([os.getpid()], kids)         # this reader (and the helpers it starts) runs under the island: it must not count as the island's load
    conf = conf_state()
    has = conf.get("has", {}) if isinstance(conf, dict) else {}
    claimed, items = set(), []

    def make(id_, kind, name, desc, seeds, follow=True, **extra):
        pids = tree(seeds, kids) if follow else set(seeds)
        pids = {p for p in pids if p in procs} - claimed - me
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
    return (dict(
        health=health_report(items, procs, os.cpu_count() or 1, meminfo, ram_lim, cpu_lim),
        items=items, procs=plist, n_procs=len(procs), suggest=suggestions(items), ncpu=os.cpu_count() or 1,
        session_mb=round(sum(p["pss"] for p in procs.values()) / 1024, 1),
        startup_mb=round(sum(it["mem"] for it in items), 1),
        total_mb=round(meminfo.get("MemTotal", 0) / 1024), avail_mb=round(meminfo.get("MemAvailable", 0) / 1024)))


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
        def num(flag, default):
            try:
                return float(a[a.index(flag) + 1]) if flag in a else default
            except (ValueError, IndexError):
                return default
        cmd_list(max(100, num("--ram", DEF_RAM_MB)), max(1, num("--cpu", DEF_CPU_PCT)), "--auto" in a)
    elif a[0] == "adapt-sample":
        cmd_adapt_sample()
    elif a[0] == "adapt-status":
        print(json.dumps(adapt_status(), indent=2))
    elif a[0] == "adapt-reset":
        cmd_adapt_reset()
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
