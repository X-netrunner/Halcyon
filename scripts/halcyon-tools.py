#!/usr/bin/env python3
"""halcyon-tools.py: the small everyday tools of Halcyon, one helper with one command per tool.

  halcyon-tools.py colorpick [hex|rgb|hsl]     pick a pixel on screen, copy its colour, show a swatch
  halcyon-tools.py measure                     drag a box on screen, copy its size (WxH) and show it
  halcyon-tools.py wifi-qr [--text]            QR code of the Wi-Fi you are on (friends scan it to join)
  halcyon-tools.py updates check|now|status|run pending pacman / AUR updates (`updates timer on` checks daily)
  halcyon-tools.py snippets list|add|rm|copy|type|pick   text you paste often ({date} {time} {clip} expand)
  halcyon-tools.py windows last|next|prev|pick|list     flip between windows (Alt+Tab)
  halcyon-tools.py mixer list|pick|set|mute    volume per app: mixer set spotify 30 | mixer mute discord
  halcyon-tools.py zoom in|out|reset|toggle    magnify the whole screen (Hyprland cursor zoom)
  halcyon-tools.py vpn status|list|up|down|toggle      NetworkManager VPN / WireGuard, or Tailscale

Everything is optional: a tool whose program is not installed says which one to install (a notification when it
was started from a key or the launcher, a line on stderr in a terminal). Nothing here needs the island to run.
Exit codes: 0 done, 1 could not do it (message printed), 2 wrong usage.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zlib
import struct

HOME = os.path.expanduser("~")
CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config")), "Halcyon")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local", "state")), "island")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(HOME, ".cache")), "island")
RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
SNIPPETS = os.path.join(CONF, "snippets.json")
IS_TTY = sys.stderr.isatty() and sys.stdin.isatty()


class Fail(Exception):
    """A tool cannot do what was asked (missing program, nothing to act on ...). The text is shown to the person."""


# --------------------------------------------------------------------------------------------- plumbing
def have(cmd):
    return shutil.which(cmd) is not None


def sh(args, inp=None, timeout=15):
    """Run a program; (returncode, stdout). A missing program or a timeout is (127 / 124, '') rather than an exception."""
    try:
        p = subprocess.run(args, input=inp, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except FileNotFoundError:
        return 127, ""
    except subprocess.TimeoutExpired:
        return 124, ""


def dispatch(lua, *legacy):
    """A Hyprland dispatcher. The Lua config (Hyprland 0.55+) only takes the Lua form ("hl.dsp.focus({ last = true })"); an older
    Hyprland only the legacy one ("focuscurrentorlast"). Both answer "ok" when they ran, and exit 0 either way, so the answer decides."""
    rc, out = sh(["hyprctl", "dispatch", lua])
    if out.strip() == "ok":
        return True
    if legacy:
        rc, out = sh(["hyprctl", "dispatch", *legacy])
        if out.strip() == "ok":
            return True
    raise Fail("Hyprland refused " + lua + ": " + (out.strip().splitlines() or [f"exit {rc}"])[0])


def need(cmd, hint=None):
    if not have(cmd):
        raise Fail(f"{cmd} is not installed" + (f" ({hint})" if hint else ""))


def notify(title, body="", icon=None, urgency=None):
    """A Halcyon notification (the island is the notification daemon). Quietly nothing when notify-send is missing."""
    if not have("notify-send"):
        return
    cmd = ["notify-send", "-a", "Halcyon"]
    if icon:
        cmd += ["-i", icon]
    if urgency:
        cmd += ["-u", urgency]
    sh(cmd + [title, body])


def copy(text):
    need("wl-copy", "pacman -S wl-clipboard")
    sh(["wl-copy"], inp=text)


def clipboard_text():
    if not have("wl-paste"):
        return ""
    rc, out = sh(["wl-paste", "--no-newline"])
    return out if rc == 0 else ""


def pick(options, prompt):
    """Let the person choose one line from `options` in fuzzel (the picker the rice already uses), else wofi / rofi.
    Returns the index chosen, or None when they closed it."""
    if not options:
        return None
    for cmd in (["fuzzel", "--dmenu", "--prompt", prompt + "> ", "--width", "50", "--lines", str(min(12, len(options)))],
                ["wofi", "--dmenu", "--prompt", prompt],
                ["rofi", "-dmenu", "-p", prompt]):
        if have(cmd[0]):
            rc, out = sh(cmd, inp="\n".join(options) + "\n", timeout=120)
            choice = out.rstrip("\n")
            if rc != 0 or choice == "":
                return None
            return options.index(choice) if choice in options else None
    raise Fail("no menu program found (install fuzzel)")


def pick_or_only(options, prompt):
    """The only option without asking, else a menu."""
    if len(options) == 1:
        return 0
    return pick(options, prompt)


def done(title, body="", icon=None):
    """Tell the person what happened: a notification, and a line in the terminal when there is one."""
    notify(title, body, icon)
    if IS_TTY or not have("notify-send"):
        print(f"{title}: {body}" if body else title)


def ensure_dir(path, mode=0o755):
    os.makedirs(path, mode=mode, exist_ok=True)


def write_private(path, data):
    ensure_dir(os.path.dirname(path), 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def forget_later(path, seconds):
    """Delete a file after a while without keeping a process around (a transient user timer)."""
    if have("systemd-run"):
        sh(["systemd-run", "--user", "--quiet", f"--on-active={seconds}s", "rm", "-f", path])


# --------------------------------------------------------------------------------------------- colour picker
def swatch_png(rgb, size=64):
    """A solid-colour PNG, written by hand so no imaging library is needed."""
    r, g, b = rgb
    row = b"\x00" + bytes((r, g, b)) * size
    raw = row * size

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def parse_hex(s):
    m = re.search(r"#?([0-9a-fA-F]{6})\b", s or "")
    if not m:
        return None
    h = m.group(1)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rgb_to_hsl(rgb):
    r, g, b = [v / 255.0 for v in rgb]
    mx, mn = max(r, g, b), min(r, g, b)
    l = (mx + mn) / 2
    if mx == mn:
        return 0, 0, round(l * 100)
    d = mx - mn
    s = d / (2 - mx - mn) if l > 0.5 else d / (mx + mn)
    if mx == r:
        h = (g - b) / d + (6 if g < b else 0)
    elif mx == g:
        h = (b - r) / d + 2
    else:
        h = (r - g) / d + 4
    return round(h * 60) % 360, round(s * 100), round(l * 100)


def format_color(rgb, fmt):
    if fmt == "rgb":
        return "rgb(%d, %d, %d)" % rgb
    if fmt == "hsl":
        return "hsl(%d, %d%%, %d%%)" % rgb_to_hsl(rgb)
    return "#%02x%02x%02x" % rgb


def read_pixel_with_grim():
    """Fallback without hyprpicker: slurp one point, grim one pixel as PPM."""
    need("slurp", "pacman -S slurp")
    need("grim", "pacman -S grim")
    rc, pt = sh(["slurp", "-p", "-f", "%x,%y 1x1"], timeout=120)
    if rc != 0 or not pt.strip():
        return None
    try:
        p = subprocess.run(["grim", "-g", pt.strip(), "-t", "ppm", "-"], capture_output=True, timeout=15)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        raise Fail("grim could not read the pixel")
    data = p.stdout
    if p.returncode != 0 or not data.startswith(b"P6"):
        raise Fail("grim could not read the pixel")
    return tuple(data[-3:])


def cmd_colorpick(args):
    fmt = (args[0] if args else "hex").lower()
    if fmt not in ("hex", "rgb", "hsl"):
        raise Fail("colorpick: format is hex, rgb or hsl")
    if have("hyprpicker"):
        rc, out = sh(["hyprpicker", "-f", "hex"], timeout=120)
        if rc != 0:
            return 1                       # Escape pressed: nothing to do
        rgb = parse_hex(out)
        if rgb is None:
            raise Fail("hyprpicker gave no colour")
    else:
        rgb = read_pixel_with_grim()
        if rgb is None:
            return 1
    text = format_color(rgb, fmt)
    copy(text)
    png = os.path.join(RUNTIME, "halcyon-swatch.png")
    try:
        write_private(png, swatch_png(rgb))
        forget_later(png, 60)
    except OSError:
        png = None
    ensure_dir(STATE)
    with open(os.path.join(STATE, "colors.log"), "a") as f:
        f.write("%d %s\n" % (time.time(), format_color(rgb, "hex")))
    done("Colour copied", text, png)
    return 0


# --------------------------------------------------------------------------------------------- measure
def cmd_measure(args):
    need("slurp", "pacman -S slurp")
    rc, out = sh(["slurp", "-f", "%w %h %x %y"], timeout=120)
    if rc != 0 or not out.strip():
        return 1
    try:
        w, h, x, y = [int(v) for v in out.split()]
    except ValueError:
        raise Fail("could not read the size")
    text = f"{w}x{h}"
    copy(text)
    done("Size copied", f"{text} px  ·  at {x},{y}")
    return 0


# --------------------------------------------------------------------------------------------- Wi-Fi QR
def wifi_escape(s):
    """The Wi-Fi QR format escapes backslash, semicolon, comma, colon and double quote with a backslash."""
    return re.sub(r'([\\;,:"])', r"\\\1", s)


def wifi_payload(ssid, password, key_mgmt):
    """WIFI:T:<WPA|WEP|nopass>;S:<ssid>;P:<password>;H:<hidden>;;  (what phone cameras understand)."""
    kind = (key_mgmt or "").strip()
    if kind in ("", "none") and not password:
        return f"WIFI:T:nopass;S:{wifi_escape(ssid)};;"
    t = "WEP" if kind == "none" else "WPA"          # wpa-psk, sae and wpa-eap-less networks all scan as WPA
    # a password that looks like hex/numbers must be quoted or phones read it as hex: wrap those in double quotes
    p = wifi_escape(password)
    if re.fullmatch(r"[0-9a-fA-F]+", password or ""):
        p = f'"{p}"'
    return f"WIFI:T:{t};S:{wifi_escape(ssid)};P:{p};;"


def current_wifi():
    need("nmcli", "pacman -S networkmanager")
    rc, out = sh(["nmcli", "-t", "-f", "active,ssid", "device", "wifi"])
    ssid = None
    for line in out.splitlines():
        if line.startswith("yes:"):
            ssid = line[4:].replace("\\:", ":")
            break
    if not ssid:
        raise Fail("not connected to Wi-Fi")
    rc, psk = sh(["nmcli", "-s", "-g", "802-11-wireless-security.psk", "connection", "show", ssid])
    rc2, km = sh(["nmcli", "-g", "802-11-wireless-security.key-mgmt", "connection", "show", ssid])
    return ssid, psk.strip(), km.strip()


def cmd_wifi_qr(args):
    ssid, psk, km = current_wifi()
    if km not in ("", "none") and not psk:
        raise Fail(f"{ssid}: the password is not saved here (company / login Wi-Fi cannot be shared as a QR)")
    payload = wifi_payload(ssid, psk, km)
    if "--text" in args:
        print(payload)
        return 0
    need("qrencode", "pacman -S qrencode")
    if IS_TTY:
        rc, out = sh(["qrencode", "-t", "ANSIUTF8", "-m", "1", payload])
        print(out)
        print(f"{ssid}: scan with your phone camera.")
        return 0
    png = os.path.join(RUNTIME, "halcyon-wifi-qr.png")
    # qrencode writes the file; make it private first because the picture holds the password
    write_private(png, b"")
    rc, _ = sh(["qrencode", "-t", "PNG", "-s", "12", "-m", "2", "-o", png, payload])
    if rc != 0:
        raise Fail("qrencode failed")
    forget_later(png, 120)
    # the island shows it big (WifiQr.qml); without the island an image viewer, and the notification either way as a last resort
    island = os.path.join(CONF, "quickshell", "island")
    shown = have("quickshell") and sh(["quickshell", "ipc", "-p", island, "call", "island", "wifiqr", png, ssid])[0] == 0
    if not shown:
        viewer = next((v for v in ("imv", "swayimg", "feh") if have(v)), None)
        if viewer:
            subprocess.Popen([viewer, png], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shown = True
    if not shown:
        notify(f"Wi-Fi QR: {ssid}", "Scan it with your phone camera. It is deleted in 2 minutes.", png)
    return 0


# --------------------------------------------------------------------------------------------- updates
def count_lines(out):
    return len([l for l in out.splitlines() if l.strip()])


def check_updates():
    """{'repo': n, 'aur': n, 'total': n, 'packages': [...]} from checkupdates (pacman-contrib) and the AUR helper."""
    if not have("checkupdates"):
        raise Fail("checkupdates is not installed (pacman -S pacman-contrib)")
    rc, out = sh(["checkupdates"], timeout=120)
    if rc not in (0, 2):                               # 2 = nothing to update
        raise Fail("checkupdates failed (no network?)")
    repo = [l.split()[0] for l in out.splitlines() if l.strip()]
    aur = []
    helper = next((h for h in ("yay", "paru") if have(h)), None)
    if helper:
        rc, out = sh([helper, "-Qua"], timeout=120)
        if rc == 0:
            aur = [l.split()[0] for l in out.splitlines() if l.strip()]
    return {"repo": len(repo), "aur": len(aur), "total": len(repo) + len(aur),
            "packages": (repo + aur)[:200], "checked": int(time.time()), "helper": helper or ""}


def updates_summary(d):
    if d["total"] == 0:
        return "Everything is up to date"
    parts = [f"{d['repo']} from the repositories"] if d["repo"] else []
    if d["aur"]:
        parts.append(f"{d['aur']} from the AUR")
    return f"{d['total']} update" + ("" if d["total"] == 1 else "s") + ": " + ", ".join(parts)


def cmd_updates(args):
    sub = args[0] if args else "status"
    cache = os.path.join(CACHE, "updates.json")
    if sub == "check":
        d = check_updates()
        ensure_dir(CACHE)
        prev = {}
        try:
            prev = json.load(open(cache))
        except (OSError, ValueError):
            pass
        d["notified"] = prev.get("notified", 0)
        # tell once per change, and only when there is a lot or it has been a while: not every day for 3 packages
        threshold = int(os.environ.get("HALCYON_UPDATES_NOTIFY", "10"))
        if d["total"] >= threshold and d["total"] != d["notified"]:
            notify("Updates are waiting", updates_summary(d) + "\nhalcyon updates run", "software-update-available")
            d["notified"] = d["total"]
        with open(cache, "w") as f:
            json.dump(d, f)
        print(updates_summary(d))
        return 0
    if sub == "now":                                   # from the launcher: check, then always say what was found
        d = check_updates()
        ensure_dir(CACHE)
        with open(cache, "w") as f:
            json.dump(dict(d, notified=d["total"]), f)
        done("Updates" if d["total"] else "No updates", updates_summary(d), "software-update-available")
        return 0
    if sub == "status":
        try:
            d = json.load(open(cache))
        except (OSError, ValueError):
            print("not checked yet (halcyon updates check)")
            return 0
        age = int((time.time() - d.get("checked", 0)) / 60)
        print(updates_summary(d) + f"  (checked {age} min ago)")
        return 0
    if sub == "timer":                                 # the daily check is opt-in: it uses the network once a day
        which = args[1] if len(args) > 1 else "status"
        if which in ("on", "off"):
            need("systemctl")
            rc, _ = sh(["systemctl", "--user", "enable" if which == "on" else "disable", "--now", "halcyon-updates.timer"])
            if rc != 0:
                raise Fail("could not switch the timer (is the user systemd running? run install.sh / update.sh once)")
            print("daily update check: " + which)
            return 0
        rc, out = sh(["systemctl", "--user", "is-enabled", "halcyon-updates.timer"])
        print("daily update check: " + ("on" if out.strip() == "enabled" else "off"))
        return 0
    if sub == "run":
        helper = next((h for h in ("yay", "paru") if have(h)), "sudo pacman")
        cmd = f"{helper} -Syu" if helper != "sudo pacman" else "sudo pacman -Syu"
        term = os.path.join(CONF, "scripts", "apps.sh")
        if os.path.exists(term):
            subprocess.Popen([term, "run", "terminal", "--", "sh", "-c", cmd + "; echo; read -p 'Done. Press Enter to close.' _"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return 0
        raise Fail(f"run this in a terminal: {cmd}")
    raise Fail("updates: check | now | status | run | timer on|off")


# --------------------------------------------------------------------------------------------- snippets
def load_snippets():
    try:
        d = json.load(open(SNIPPETS))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_snippets(d):
    ensure_dir(CONF)
    tmp = SNIPPETS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, SNIPPETS)


def expand(text, now=None, clip=None):
    """{date} {time} {clip} inside a snippet."""
    now = now or time.localtime()
    out = text.replace("{date}", time.strftime("%Y-%m-%d", now)).replace("{time}", time.strftime("%H:%M", now))
    if "{clip}" in out:
        out = out.replace("{clip}", clipboard_text() if clip is None else clip)
    return out


def type_text(text):
    """Type it into the focused window with wtype; without wtype copy it and press Ctrl+V."""
    if have("wtype"):
        sh(["wtype", "--", text])
        return
    copy(text)
    if have("hyprctl"):
        time.sleep(0.15)
        dispatch('hl.dsp.send_shortcut({ mods = "CTRL", key = "V" })', "sendshortcut", "CTRL,V,activewindow")


def cmd_snippets(args):
    sub = args[0] if args else "list"
    rest = args[1:]
    d = load_snippets()
    if sub == "list":
        for k in sorted(d):
            print(f"{k:<16} {d[k].splitlines()[0][:70] if d[k] else ''}")
        if not d:
            print("no snippets yet: halcyon snippets add <name> [text]   ({date} {time} {clip} are filled in when it is typed)")
        return 0
    if sub == "add":
        if not rest:
            raise Fail("snippets add <name> [text]   (no text: reads the clipboard, or a pipe)")
        name = rest[0]
        if not re.fullmatch(r"[\w.\-]{1,32}", name):
            raise Fail("a snippet name is 1 to 32 letters, digits, - . _")
        text = " ".join(rest[1:]) if len(rest) > 1 else ("" if sys.stdin.isatty() else sys.stdin.read().rstrip("\n"))
        if not text:
            text = clipboard_text()
        if not text:
            raise Fail("nothing to save: give the text, pipe it in, or copy it first")
        d[name] = text
        save_snippets(d)
        done("Snippet saved", name)
        return 0
    if sub == "rm":
        if not rest or rest[0] not in d:
            raise Fail("no such snippet")
        del d[rest[0]]
        save_snippets(d)
        return 0
    if sub in ("copy", "type"):
        if not rest or rest[0] not in d:
            raise Fail("no such snippet (halcyon snippets list)")
        text = expand(d[rest[0]])
        copy(text) if sub == "copy" else type_text(text)
        return 0
    if sub == "pick":
        if not d:
            done("No snippets yet", "halcyon snippets add <name> <text>")
            return 1
        names = sorted(d)
        rows = [f"{n}  ·  {d[n].splitlines()[0][:60]}" for n in names]
        i = pick(rows, "Snippet")
        if i is None:
            return 1
        type_text(expand(d[names[i]]))
        return 0
    raise Fail("snippets: list | add | rm | copy | type | pick")


# --------------------------------------------------------------------------------------------- windows
def hypr_clients():
    need("hyprctl")
    rc, out = sh(["hyprctl", "clients", "-j"])
    try:
        cl = json.loads(out)
    except ValueError:
        raise Fail("hyprctl gave no window list (is Hyprland running?)")
    return [c for c in cl if c.get("mapped", True) and not c.get("hidden", False)]


def window_order(clients):
    """A steady order to cycle through: by workspace, then left to right, then top to bottom."""
    return sorted(clients, key=lambda c: (c.get("workspace", {}).get("id", 0), c.get("at", [0, 0])[0], c.get("at", [0, 0])[1]))


def window_label(c):
    ws = c.get("workspace", {}).get("name") or c.get("workspace", {}).get("id", "?")
    title = (c.get("title") or "").strip() or c.get("class", "")
    return f"{c.get('class', '?')}  ·  {title[:60]}  [{ws}]"


def focus(c):
    dispatch(f'hl.dsp.focus({{ window = "address:{c["address"]}" }})', "focuswindow", f"address:{c['address']}")
    dispatch("hl.dsp.window.bring_to_top()", "bringactivetotop")


def next_window(clients, active_addr, step):
    order = window_order(clients)
    if not order:
        return None
    idx = next((i for i, c in enumerate(order) if c["address"] == active_addr), -1)
    return order[(idx + step) % len(order)]


def cmd_windows(args):
    sub = args[0] if args else "last"
    if sub == "last":
        need("hyprctl")
        dispatch("hl.dsp.focus({ last = true })", "focuscurrentorlast")
        return 0
    clients = hypr_clients()
    if sub == "list":
        for c in window_order(clients):
            print(window_label(c))
        return 0
    if sub in ("next", "prev"):
        rc, out = sh(["hyprctl", "activewindow", "-j"])
        try:
            active = json.loads(out).get("address", "")
        except ValueError:
            active = ""
        c = next_window(clients, active, 1 if sub == "next" else -1)
        if c is None:
            return 1
        focus(c)
        return 0
    if sub == "pick":
        order = sorted(clients, key=lambda c: c.get("focusHistoryID", 99))      # most recently used first
        i = pick([window_label(c) for c in order], "Window")
        if i is None:
            return 1
        focus(order[i])
        return 0
    raise Fail("windows: last | next | prev | pick | list")


# --------------------------------------------------------------------------------------------- mixer
def parse_inputs(js):
    """pactl -f json list sink-inputs -> [{'id', 'name', 'media', 'vol', 'mute'}]"""
    out = []
    for e in js:
        pr = e.get("properties", {})
        vols = [int(str(v.get("value_percent", "0%")).rstrip("%") or 0) for v in (e.get("volume") or {}).values()]
        out.append({"id": e.get("index"), "mute": bool(e.get("mute")),
                    "name": pr.get("application.name") or pr.get("application.process.binary") or "?",
                    "binary": pr.get("application.process.binary", ""), "media": pr.get("media.name", ""),
                    "vol": max(vols) if vols else 0})
    return out


def sink_inputs():
    need("pactl", "pacman -S libpulse")
    rc, out = sh(["pactl", "-f", "json", "list", "sink-inputs"])
    if rc != 0:
        raise Fail("pactl could not list the playing apps (is PipeWire running?)")
    try:
        return parse_inputs(json.loads(out or "[]"))
    except ValueError:
        raise Fail("pactl gave an answer it could not read (pactl is older than 15?)")


def match_inputs(inputs, needle):
    n = needle.lower()
    return [i for i in inputs if n in i["name"].lower() or n in i["binary"].lower() or n in i["media"].lower()]


def parse_level(s, cur):
    """'30' -> 30, '+5' -> cur + 5, '-10' -> cur - 10, clamped to 0..150."""
    m = re.fullmatch(r"([+-]?)(\d{1,3})%?", s.strip())
    if not m:
        raise Fail("volume is a number (30), or +5 / -10")
    n = int(m.group(2))
    v = cur + n if m.group(1) == "+" else (cur - n if m.group(1) == "-" else n)
    return max(0, min(150, v))


def cmd_mixer(args):
    sub = args[0] if args else "list"
    ins = sink_inputs()
    if sub == "list":
        if not ins:
            print("nothing is playing sound")
        for i in ins:
            print(f"{i['name']:<20} {i['vol']:>3}%{'  (muted)' if i['mute'] else ''}   {i['media'][:50]}")
        return 0
    if sub == "pick":                                  # from the launcher: choose an app, then a level
        if not ins:
            done("Mixer", "nothing is playing sound")
            return 1
        i = pick_or_only([f"{i['name']}  ·  {i['vol']}%" for i in ins], "App")
        if i is None:
            return 1
        levels = ["mute / unmute", "0", "25", "50", "75", "100", "125"]
        j = pick(levels, ins[i]["name"])
        if j is None:
            return 1
        sh(["pactl", "set-sink-input-mute", str(ins[i]["id"]), "toggle"] if j == 0
           else ["pactl", "set-sink-input-volume", str(ins[i]["id"]), levels[j] + "%"])
        return 0
    if sub in ("set", "mute", "unmute"):
        if len(args) < 2:
            raise Fail(f"mixer {sub} <app>" + (" <0-150 | +5 | -5>" if sub == "set" else ""))
        hits = match_inputs(ins, args[1])
        if not hits:
            raise Fail(f"no app called '{args[1]}' is playing sound (halcyon mixer list)")
        for i in hits:
            if sub == "set":
                if len(args) < 3:
                    raise Fail("mixer set <app> <0-150 | +5 | -5>")
                sh(["pactl", "set-sink-input-volume", str(i["id"]), f"{parse_level(args[2], i['vol'])}%"])
            else:
                sh(["pactl", "set-sink-input-mute", str(i["id"]), "toggle" if len(args) > 2 and args[2] == "toggle" else ("1" if sub == "mute" else "0")])
        done("Mixer", ", ".join(sorted({i["name"] for i in hits})))
        return 0
    raise Fail("mixer: list | pick | set <app> <level> | mute <app> | unmute <app>")


# --------------------------------------------------------------------------------------------- zoom
def zoom_get():
    need("hyprctl")
    rc, out = sh(["hyprctl", "getoption", "cursor:zoom_factor", "-j"])
    try:
        return float(json.loads(out).get("float", 1.0))
    except (ValueError, TypeError):
        return 1.0


def zoom_next(cur, sub):
    if sub == "in":
        return min(10.0, round(cur + 0.5, 2) if cur >= 1 else 1.5)
    if sub == "out":
        return max(1.0, round(cur - 0.5, 2))
    if sub == "reset":
        return 1.0
    return 1.0 if cur > 1.0 else 2.0                 # toggle


def cmd_zoom(args):
    sub = args[0] if args else "toggle"
    if sub not in ("in", "out", "reset", "toggle"):
        raise Fail("zoom: in | out | reset | toggle")
    z = zoom_next(zoom_get(), sub)
    # the Lua config (Hyprland 0.55+) refuses `hyprctl keyword` and still exits 0, so eval first and keyword only as the fallback
    rc, out = sh(["hyprctl", "eval", f"hl.config({{ cursor = {{ zoom_factor = {z} }} }})"])
    if out.strip() != "ok":
        rc, out = sh(["hyprctl", "keyword", "cursor:zoom_factor", str(z)])
        if out.strip() != "ok":
            raise Fail("Hyprland did not take the zoom: " + (out.strip() or f"exit {rc}"))
    return 0


# --------------------------------------------------------------------------------------------- VPN
def nm_vpns():
    """[(name, type, active)] of the saved VPN and WireGuard connections."""
    need("nmcli", "pacman -S networkmanager")
    rc, out = sh(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show"])
    vpns = []
    for line in out.splitlines():
        parts = re.split(r"(?<!\\):", line)
        if len(parts) >= 3 and parts[1] in ("vpn", "wireguard"):
            vpns.append((parts[0].replace("\\:", ":"), parts[1], bool(parts[2])))
    rc, act = sh(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active"])
    active = {re.split(r"(?<!\\):", l)[0].replace("\\:", ":") for l in act.splitlines() if re.split(r"(?<!\\):", l)[-1] in ("vpn", "wireguard")}
    return [(n, t, n in active) for n, t, _ in vpns]


def tailscale_up():
    if not have("tailscale"):
        return None
    rc, out = sh(["tailscale", "status", "--json"])
    if rc != 0:
        return False
    try:
        return json.loads(out).get("BackendState") == "Running"
    except ValueError:
        return False


def cmd_vpn(args):
    sub = args[0] if args else "status"
    name = " ".join(args[1:]) if len(args) > 1 else ""
    vpns = nm_vpns() if have("nmcli") else []
    ts = tailscale_up()
    if not vpns and ts is None:
        raise Fail("no VPN found: add one in NetworkManager (nmcli connection import type wireguard file x.conf) or install tailscale")
    if sub in ("status", "list"):
        for n, t, a in vpns:
            print(f"{'on ' if a else 'off'}  {n}  ({t})")
        if ts is not None:
            print(f"{'on ' if ts else 'off'}  tailscale")
        return 0
    if sub in ("up", "down", "toggle"):
        any_on = any(a for _, _, a in vpns) or bool(ts)
        want_up = (sub == "up") or (sub == "toggle" and not any_on)
        if not want_up:
            for n, _, a in vpns:
                if a and (not name or name.lower() in n.lower()):
                    sh(["nmcli", "connection", "down", n], timeout=30)
            if ts and (not name or name.lower() == "tailscale"):
                sh(["tailscale", "down"], timeout=30)
            done("VPN off")
            return 0
        names = [n for n, _, _ in vpns] + (["tailscale"] if ts is not None else [])
        if name:
            hit = [n for n in names if name.lower() in n.lower()]
            if not hit:
                raise Fail(f"no VPN called '{name}'")
            target = hit[0]
        else:
            i = pick_or_only(names, "VPN")
            if i is None:
                return 1
            target = names[i]
        if target == "tailscale":
            rc, _ = sh(["tailscale", "up"], timeout=60)
        else:
            rc, _ = sh(["nmcli", "connection", "up", target], timeout=60)
        if rc != 0:
            raise Fail(f"could not connect {target}")
        done("VPN on", target)
        return 0
    raise Fail("vpn: status | list | up [name] | down [name] | toggle")


# --------------------------------------------------------------------------------------------- main
COMMANDS = {
    "colorpick": cmd_colorpick, "color": cmd_colorpick, "measure": cmd_measure, "wifi-qr": cmd_wifi_qr,
    "updates": cmd_updates, "snippets": cmd_snippets, "snippet": cmd_snippets, "windows": cmd_windows,
    "mixer": cmd_mixer, "zoom": cmd_zoom, "vpn": cmd_vpn,
}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if argv else 2
    fn = COMMANDS.get(argv[0])
    if fn is None:
        print(f"halcyon-tools: unknown tool '{argv[0]}' (--help lists them)", file=sys.stderr)
        return 2
    try:
        return fn(argv[1:]) or 0
    except Fail as e:
        msg = str(e)
        if IS_TTY or not have("notify-send"):
            print(f"halcyon {argv[0]}: {msg}", file=sys.stderr)
        else:
            notify("Halcyon: " + argv[0], msg, "dialog-warning")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
