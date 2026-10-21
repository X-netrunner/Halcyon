#!/usr/bin/env python3
"""halcyon-shot.py: the screenshot panel's engine (Super + Ctrl + S, >screenshot in the launcher, `halcyon screenshot`).

  halcyon-shot.py region [ACTION]     drag a rectangle (the screen freezes first when wayfreeze is installed)
  halcyon-shot.py window [ACTION]     click a window (any you can see now, on every screen)
  halcyon-shot.py full   [ACTION]     the whole screen the pointer / focus is on
  halcyon-shot.py conf                one line of JSON for the panel: {"action", "dir", "has": {...}}
  halcyon-shot.py set action ACTION   remember the choice the panel opens with

ACTION is  copy  (clipboard only, no file)  |  save  (file only)  |  both  (file and clipboard, what Super + Shift + S does)
        |  text  (read the words in the picture with tesseract, offline, and put the TEXT on the clipboard; no picture is kept).
Without one, the remembered choice is used (state/shot.json, "both" at first).

Files go to ~/Pictures/Screenshots/<seconds>.png, the same place and name as the existing shortcuts. This is a one-shot command:
it starts nothing that stays, and cancelling the selection (Esc) leaves no file, no clipboard change and no notification.
The existing Super + Shift + S (scripts/screenshot-area.sh), Print and Super + Shift + Print are not touched.
Exit status: 0 done or cancelled, 1 a tool is missing or the capture failed, 2 usage.
"""
import json
import os
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATE = os.environ.get("HALCYON_STATE") or os.path.join(HOME, ".local", "state", "island")
CONF = os.path.join(STATE, "shot.json")
OUT_DIR = os.environ.get("HALCYON_SHOT_DIR") or os.path.join(HOME, "Pictures", "Screenshots")
ACTIONS = ("copy", "save", "both", "text")
MODES = ("region", "window", "full")
HINT = "string:x-canonical-private-synchronous:screenshot"


def have(c):
    return shutil.which(c) is not None


def read_conf():
    try:
        with open(CONF, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def saved_action():
    a = read_conf().get("action")
    return a if a in ACTIONS else "both"


def write_conf(d):
    try:
        os.makedirs(STATE, exist_ok=True)
        tmp = CONF + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f)
        os.replace(tmp, CONF)
        return True
    except OSError:
        return False


def notify(body, icon=None):
    if not have("notify-send"):
        return
    cmd = ["notify-send", "Screenshot", body, "-h", HINT]
    if icon and os.path.exists(icon):
        cmd += ["-i", icon]
    try:
        subprocess.run(cmd, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        pass


def hypr_json(what):
    if not have("hyprctl"):
        return None
    try:
        r = subprocess.run(["hyprctl", what, "-j"], capture_output=True, timeout=5)
        return json.loads(r.stdout.decode("utf-8", "replace")) if r.returncode == 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def window_boxes():
    """slurp input lines 'x,y WxH label' for every window you can see now (the visible workspace of each screen, and a shown
    special workspace)."""
    clients = hypr_json("clients")
    mons = hypr_json("monitors") or []
    if not isinstance(clients, list):
        return []
    visible = set()
    for m in mons if isinstance(mons, list) else []:
        try:
            visible.add(int((m.get("activeWorkspace") or {}).get("id")))
        except (TypeError, ValueError):
            pass
        try:
            sp = int((m.get("specialWorkspace") or {}).get("id") or 0)
            if sp:
                visible.add(sp)
        except (TypeError, ValueError):
            pass
    out = []
    for c in clients:
        try:
            if c.get("mapped") is False or c.get("hidden"):
                continue
            if visible and int((c.get("workspace") or {}).get("id")) not in visible:
                continue
            x, y = (int(v) for v in c["at"])
            w, h = (int(v) for v in c["size"])
        except (KeyError, TypeError, ValueError):
            continue
        if w <= 0 or h <= 0:
            continue
        label = " ".join(("%s %s" % (c.get("class") or "", c.get("title") or "")).split())[:60]
        out.append("%d,%d %dx%d %s" % (x, y, w, h, label))
    return out


def focused_output():
    mons = hypr_json("monitors")
    if isinstance(mons, list):
        for m in mons:
            if m.get("focused") and m.get("name"):
                return str(m["name"])
    return None


def pick(cmd, stdin_text=None):
    """run slurp; '' when the selection was cancelled."""
    try:
        r = subprocess.run(cmd, input=stdin_text.encode() if stdin_text is not None else None, capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""


def start_freeze():
    if not have("wayfreeze"):
        return None
    try:
        p = subprocess.Popen(["wayfreeze"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        time.sleep(0.2)
        return p
    except OSError:
        return None


def stop_freeze(p):
    if p is None:
        return
    try:
        p.terminate()
        p.wait(timeout=2)
    except (OSError, subprocess.SubprocessError):
        try:
            p.kill()
        except OSError:
            pass


def new_path():
    os.makedirs(OUT_DIR, exist_ok=True)
    base = str(int(time.time()))
    p = os.path.join(OUT_DIR, base + ".png")
    n = 1
    while os.path.exists(p):          # two shots in one second must not overwrite each other
        p = os.path.join(OUT_DIR, "%s-%d.png" % (base, n))
        n += 1
    return p


def to_clipboard(data):
    p = subprocess.Popen(["wl-copy", "--type", "image/png"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    p.stdin.write(data)
    p.stdin.close()
    return p.wait(timeout=10) == 0


def ocr_to_clipboard(png):
    """Action "text": the words in the picture go on the clipboard (tesseract, offline; it copies what is there, nothing is invented)."""
    lang = os.environ.get("HALCYON_OCR_LANG") or "eng"
    try:
        t = subprocess.run(["tesseract", "stdin", "stdout", "-l", lang], input=png, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        notify("Reading the text failed")
        return 1
    text = t.stdout.decode("utf-8", "replace").strip()
    if not text:
        if t.returncode != 0:
            notify("Reading the text failed (is the language data installed? tesseract-data-" + lang + ")")
            return 1
        notify("No text found in the picture")
        return 0
    try:
        ok = subprocess.run(["wl-copy"], input=text.encode("utf-8"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    # the clipboard history's sparkle (or `halcyon ai clip summarise`) can summarise / rewrite what was read
    notify(("Text copied (%d characters). Clipboard history > ✦ summarises it" % len(text)) if ok else "Could not copy the text")
    return 0 if ok else 1


def shoot(mode, action):
    if action not in ACTIONS:
        print("halcyon-shot: action must be copy, save, both or text", file=sys.stderr)
        return 2
    missing = [c for c in (["grim"] + (["slurp"] if mode != "full" else []) + (["wl-copy"] if action != "save" else []) + (["tesseract"] if action == "text" else [])) if not have(c)]
    if missing:
        msg = "needs " + ", ".join(missing)
        print("halcyon-shot: " + msg, file=sys.stderr)
        notify("Cannot capture: " + msg)
        return 1

    boxes = []
    if mode == "window":
        boxes = window_boxes()
        if not boxes:
            notify("No window to pick here")
            return 0
    freeze = start_freeze() if mode in ("region", "window") else None
    try:
        grim = ["grim"]
        if mode == "region":
            geom = pick(["slurp", "-d"])
            if not geom:
                return 0                                   # cancelled: nothing happens
            grim += ["-g", geom]
        elif mode == "window":
            geom = pick(["slurp", "-r"], "\n".join(boxes) + "\n")
            if not geom:
                return 0
            grim += ["-g", geom]
        else:
            out = focused_output()
            if out:
                grim += ["-o", out]

        path = None
        if action in ("save", "both"):
            try:
                path = new_path()
            except OSError:
                notify("Cannot write to " + OUT_DIR.replace(HOME, "~"))
                print("halcyon-shot: cannot write to " + OUT_DIR, file=sys.stderr)
                return 1
        try:
            r = subprocess.run(grim + [path if path else "-"], capture_output=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            r = None
        if r is None or r.returncode != 0:
            if path and os.path.exists(path) and os.path.getsize(path) == 0:
                os.remove(path)                            # no empty file left behind
            notify("The capture failed")
            return 1
        stop_freeze(freeze)
        freeze = None

        if action == "text":
            return ocr_to_clipboard(r.stdout)

        if path:
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                data = b""
        else:
            data = r.stdout
        copied = False
        if action != "save":
            try:
                copied = bool(data) and to_clipboard(data)
            except (OSError, subprocess.SubprocessError):
                copied = False
        if action == "save":
            notify("Saved to " + path.replace(HOME, "~"), path)
        elif action == "copy":
            notify("Copied" if copied else "Could not copy it", None)
            return 0 if copied else 1
        else:
            notify("Saved and copied" if copied else "Saved (could not copy)", path)
        return 0
    finally:
        stop_freeze(freeze)


def main(argv):
    a = argv[1:]
    if not a:
        a = ["conf"]
    c = a[0]
    if c == "conf":
        print(json.dumps({
            "action": saved_action(),
            "dir": OUT_DIR,
            "has": {t: have(t) for t in ("grim", "slurp", "wl-copy", "wayfreeze", "hyprctl", "tesseract")},
        }))
        return 0
    if c == "set":
        if len(a) == 3 and a[1] == "action" and a[2] in ACTIONS:
            d = read_conf()
            d["action"] = a[2]
            return 0 if write_conf(d) else 1
        print("usage: halcyon-shot.py set action copy|save|both|text", file=sys.stderr)
        return 2
    if c in MODES:
        return shoot(c, a[1] if len(a) > 1 else saved_action())
    print("usage: halcyon-shot.py region|window|full [copy|save|both|text] | conf | set action copy|save|both|text", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
